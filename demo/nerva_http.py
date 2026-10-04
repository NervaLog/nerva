"""A small client for `nerva api` and `nerva view`, for the demos (standard library only)."""
import http.client, json


class Unavailable(Exception):
    """The process did not answer: it may be crashed or restarting. A commit that raised this
    may or may not have committed."""


class Http:
    """Requests to one port, one connection each: Nerva's gateways close a connection after one
    reply (docs/DECISIONS.md N37). Never retried here, so a commit is never sent twice."""

    def __init__(self, port, key, timeout=15):
        self.port, self.key, self.timeout = port, key, timeout

    def request(self, method, target, body=None):
        connection = http.client.HTTPConnection("127.0.0.1", self.port, timeout=self.timeout)
        try:
            data = json.dumps(body) if body is not None else None
            connection.request(method, target, body=data,
                               headers={"X-Nerva-Key": self.key,
                                        "Content-Type": "application/json"})
            response = connection.getresponse()
            text = response.read()
        except (OSError, http.client.HTTPException):
            raise Unavailable(f"port {self.port}")
        finally:
            connection.close()
        # `/healthz` on `nerva view` answers in the ledger protocol's text, not JSON.
        try:
            return response.status, json.loads(text or b"null")
        except ValueError:
            return response.status, text.decode(errors="replace")
