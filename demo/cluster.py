"""A Nerva cluster for demos: three replicas, `nerva api`, and two `nerva view` processes, with
controls to crash and restart any of them (docs/DECISIONS.md N36).

Python standard library only. Ports are fixed from a base port, so a crashed process restarts
where clients expect it:

    base + 0..2   replicas          base + 10   nerva api          base + 20, 21   nerva view

Crashes are SIGKILL: no shutdown path runs, as in a power cut. The supervisor keeps quorum: it
refuses to stop a second replica while one is down, so a demo never stalls.
"""
import os, signal, subprocess, threading, time

REPLICAS = 3


class Process:
    def __init__(self, name, argv, env, log_path):
        self.name, self.argv, self.env, self.log_path = name, argv, env, log_path
        self.popen = None
        self.started_at = None
        self.crashes = 0

    def start(self):
        assert not self.alive()
        log = open(self.log_path, "a")
        # stdin is a pipe kept open: `nerva start --addresses=0` style exits when it closes.
        self.popen = subprocess.Popen(self.argv, stdin=subprocess.PIPE, stdout=log, stderr=log,
                                      env=self.env, start_new_session=True)
        self.started_at = time.time()

    def kill(self):
        if self.alive():
            os.killpg(self.popen.pid, signal.SIGKILL)
            self.popen.wait()
            self.crashes += 1

    def alive(self):
        return self.popen is not None and self.popen.poll() is None


class Cluster:
    def __init__(self, nerva, data_dir, base_port, key, cluster_id=1):
        self.nerva, self.data_dir, self.base_port, self.key = nerva, data_dir, base_port, key
        self.cluster_id = cluster_id
        self.lock = threading.Lock()
        os.makedirs(data_dir, exist_ok=True)
        addresses = ",".join(str(base_port + i) for i in range(REPLICAS))
        env = {**os.environ, "NERVA_KEY": key}

        self.replicas = []
        for index in range(REPLICAS):
            path = os.path.join(data_dir, f"{cluster_id}_{index}.nerva")
            if not os.path.exists(path):
                subprocess.run([nerva, "format", f"--cluster={cluster_id}", f"--replica={index}",
                                f"--replica-count={REPLICAS}", "--development", path],
                               check=True, capture_output=True)
            self.replicas.append(Process(
                f"replica {index}",
                [nerva, "start", f"--addresses={addresses}", "--development", path], env,
                os.path.join(data_dir, f"replica_{index}.log")))

        def client(name, command, port):
            return Process(name, [nerva, command, f"--cluster={cluster_id}",
                                  f"--addresses={addresses}", f"--listen=127.0.0.1:{port}"],
                           env, os.path.join(data_dir, f"{name.replace(' ', '_')}.log"))

        self.api = client("api", "api", self.api_port)
        self.views = [client("view a", "view", self.view_ports[0]),
                      client("view b", "view", self.view_ports[1])]

    @property
    def api_port(self):
        return self.base_port + 10

    @property
    def view_ports(self):
        return [self.base_port + 20, self.base_port + 21]

    def processes(self):
        return self.replicas + [self.api] + self.views

    def start(self):
        for process in self.processes():
            process.start()

    def stop(self):
        for process in self.processes():
            process.kill()

    def status(self):
        return [{"name": p.name, "alive": p.alive(), "crashes": p.crashes}
                for p in self.processes()]

    def crash(self, name):
        """Kills the named process. Returns why not, or None."""
        with self.lock:
            process = next((p for p in self.processes() if p.name == name), None)
            if process is None:
                return "no such process"
            if not process.alive():
                return f"{name} is already down"
            if process in self.replicas and any(not r.alive() for r in self.replicas):
                return "one replica is already down: stopping another would lose quorum"
            process.kill()
            return None

    def restart(self, name):
        with self.lock:
            process = next((p for p in self.processes() if p.name == name), None)
            if process is None:
                return "no such process"
            if process.alive():
                return f"{name} is running"
            process.start()
            return None
