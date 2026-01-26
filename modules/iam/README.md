Love it. This is already a solid “PG is the ledger of principals” core. A few tweaks will buy you *years* of
optionality (multiple auth methods, safer uniqueness, cleaner entitlements, better invariants) without bloating MVP.

## What you have is good

* **`org` + `user` + `org_membership`** is the right triad.
* The **partial unique index** for one primary owner is the right instinct.
* Keeping `plan_key` + `seats_limit` cached in `org` is practical (even if Stripe is canonical for billing).

## The main change I’d make immediately

### Rename `provider_user_id` → `stytch_member_id` (or `stytch_user_id`) and make it nullable

Right now you’ve baked in “every user always has Stytch, and it’s the only provider.”

If PG is the source of truth, you want the ability to have:

* pending/invited users not bound yet
* more than one provider per user (magic link + Google + GitHub + later Apple)
* provider migration / rotation

So: keep the “current Stytch binding” on `users` as a convenience pointer, but don’t force it to exist.

```sql
alter table ${iam.user_table}
    rename column provider_user_id to stytch_member_id;

alter table ${iam.user_table}
    alter column stytch_member_id drop not null;

create unique index if not exists users_stytch_member_unique
    on ${iam.user_table} (stytch_member_id)
    where stytch_member_id is not null;
```

## Add an `identities` table (this is the big optionality unlock)

This gives you:

* multiple login methods per user
* future Apple (custom) / SSO (SAML/OIDC) / passkeys / API tokens
* clean “binding” logic without email as a forever-key

```sql
do
$$
    begin
        create type auth_provider as enum (
            'stytch_magic_link',
            'stytch_google',
            'stytch_github',
            'apple_custom',
            'sso_saml',
            'sso_oidc'
            );
    exception
        when duplicate_object then null;
    end
$$;

create table if not exists ${iam.schema}.user_identities
(
    id               uuid primary key       default gen_random_uuid(),
    user_id          uuid          not null references ${iam.user_table} (id) on delete cascade,

    provider         auth_provider not null,
    provider_subject text          not null, -- stable sub from provider (NOT email)
    email_at_auth    text,
    phone_at_auth    text,

    created_at       timestamptz   not null default now(),
    last_used_at     timestamptz,

    unique (provider, provider_subject)
);

create index if not exists user_identities_user_id_idx
    on ${iam.schema}.user_identities (user_id);
```

**Flow-wise:** when Stytch returns a successful auth, you upsert `(provider, provider_subject)` to bind to a PG user.

## Use `citext` for email and slug

You already hinted at citext earlier — do it here too. It removes a bunch of edge cases.

```sql
create extension if not exists citext;

alter table ${iam.user_table}
    alter column email type citext;

alter table ${iam.org_table}
    alter column slug type citext;

-- Replace lower(email) index with direct unique index
drop index if exists users_email_unique;
create unique index if not exists users_email_unique
    on ${iam.user_table} (email)
    where email is not null;
```

## Make owner invariants harder to violate

Your `is_primary_owner` partial unique is good, but it doesn’t guarantee:

* at least one owner exists
* primary owner must have role owner/admin
* exactly one primary owner (you have)
* an org can’t end up with **zero owners** after updates

Add a lightweight trigger to enforce invariants on membership changes:

```sql
create or replace function ${iam.schema}.enforce_org_owner_invariants()
    returns trigger
    language plpgsql as
$$
begin
    -- primary owner must have role owner
    if new.is_primary_owner and new.role <> 'owner' then
        raise exception 'primary owner must have role=owner';
    end if;

    return new;
end
$$;

drop trigger if exists trg_org_owner_invariants on ${iam.org_membership_table};
create trigger trg_org_owner_invariants
    before insert or update
    on ${iam.org_membership_table}
    for each row
execute function ${iam.schema}.enforce_org_owner_invariants();
```

The “cannot remove last owner” rule is best enforced in the *service layer* (because you often need a transaction that
promotes someone else + demotes old owner). But if you want it in PG, it’s doable with deferrable constraints /
triggers; I’d keep it app-level for MVP.

## Add `updated_at` triggers (you’ll want them everywhere)

You’re tracking `updated_at` but nothing updates it.

```sql
create or replace function ${iam.schema}.touch_updated_at()
    returns trigger
    language plpgsql as
$$
begin
    new.updated_at = now();
    return new;
end
$$;

drop trigger if exists trg_users_touch on ${iam.user_table};
create trigger trg_users_touch
    before update
    on ${iam.user_table}
    for each row
execute function ${iam.schema}.touch_updated_at();

drop trigger if exists trg_orgs_touch on ${iam.org_table};
create trigger trg_orgs_touch
    before update
    on ${iam.org_table}
    for each row
execute function ${iam.schema}.touch_updated_at();
```

## Entitlements: keep `plan_key`, but plan for “derived truth”

Your `plan_key` + `seats_limit` is fine as a cached copy, but you’ll quickly want:

* `seats_used` (derived from membership count excluding disabled users)
* a way to lock writes when suspended/deleted

At minimum, add a view for seat accounting:

```sql
create or replace view ${iam.schema}.org_seat_usage as
select o.id                                        as org_id,
       o.seats_limit,
       count(*) filter (where u.status = 'active') as seats_used
from ${iam.org_table} o
         join ${iam.org_membership_table} m on m.org_id = o.id
         join ${iam.user_table} u on u.id = m.user_id
where o.status = 'active'
group by o.id, o.seats_limit;
```

## Custom claims guidance (now that PG is truth)

If you mint session claims at all, make them **non-authoritative hints**:

* `org_id`
* `user_id`
* maybe `role` as a cache, but still check PG for real

Your API should always do: “Stytch session valid?” → “PG principal active and authorized?”

## One more tiny nit: `email_verified` / `phone_verified`

If PG is truth, treat these as **“verified by authenticator X at time T”**, not eternal truth. The identities table
makes this clean (`email_at_auth`, `last_used_at`). If you keep the booleans, consider also storing timestamps:

* `email_verified_at timestamptz`
* `phone_verified_at timestamptz`

It’ll matter in support/debug.

---

### If you only do two changes this week

1. **Add `user_identities`** (provider + subject)
2. **Convert email + slug to `citext`** and add `updated_at` triggers

Everything else can follow.

If you want, paste your intended Stytch callback payload shape (what fields you get back for magic link + google oauth),
and I’ll give you the exact upsert/binding SQL (and the transaction boundaries) so “PG is truth” stays airtight under
concurrency.

---
Short answer: **you lose sovereignty, composability, and some long-term strategic degrees of freedom**—but you *gain speed and reduced cognitive load*. Whether that trade is acceptable depends on how seriously you mean “WorldOps / ledger-of-record” for identity.

Below is the **optionality you give up** if you let **Stytch** be *authority* (not just auth transport).

---

## The frame: authority vs transport

* **Transport model**: Stytch proves identity, issues sessions.
  PG decides *who exists*, *what they can do*, *what’s true*.
* **Authority model**: Stytch decides who exists and in what state; PG mirrors.

Your question is about the **delta** between those worlds.

---

## 1. Identity as a ledger (lost)

If Stytch is authority, you **cannot treat identity as a first-class ledger**.

You lose the ability to:

* model identity lifecycle as **append-only events**
* reason about *why* someone exists (invite, import, migration, support action)
* represent “pre-identity” states cleanly (pending, escrowed, disputed)

Instead:

* identity is CRUD-ish, mutable, and external
* state transitions are implicit in Stytch behavior, not explicit in your system

This matters if:

* identity is tied to money, reputation, or compliance
* you ever want to *prove* who knew what when

> Ledger mindset dies the moment identity truth lives outside your DB.

---

## 2. Arbitrary identity composition (lost)

When Stytch is authority, your identity model becomes constrained to:

* members
* orgs
* roles
* sessions
* whatever Stytch exposes this quarter

You lose optionality to model things like:

* **multiple principals per human** (e.g., creator vs operator vs delegate)
* **non-human identities** (automations, relays, escrow agents)
* **conditional or scoped identities** (time-boxed, action-boxed, revocable)

With PG as authority, identity can be:

* a *function of context*
* a projection, not a row

With Stytch as authority, identity is:

* a fixed object with attributes

That’s a real expressive loss.

---

## 3. Multi-auth unification (lost)

If Stytch is authority, *each* of these becomes awkward:

* Apple via custom flow
* government ID / KYC
* hardware-backed identities
* future wallet-based auth
* delegated auth (e.g. “assistant logs in *as* creator”)

Why?
Because you’re forced to map **everything** into Stytch’s notion of “member”.

If PG is authority:

* Stytch is just *one* authenticator among many
* others can be added without reshaping your core model

Authority in Stytch collapses the possibility space.

---

## 4. Deterministic authorization (lost)

Once Stytch is authority, **authorization pressure leaks upward**:

* you start trusting session claims
* you start caching role/plan in JWTs
* revocation becomes eventually consistent

That breaks:

* immediate disable
* strong RLS invariants
* “PG answers every authz question” simplicity

You *can* mitigate—but you’ll fight gravity forever.

---

## 5. Clean vendor exit (lost)

This one is subtle but important.

If Stytch is authority:

* your canonical IDs are theirs
* your users’ identity history is theirs
* your flows assume their semantics

Exiting later requires:

* dual-writing identities
* replaying history
* freezing features during migration
* explaining auth weirdness to users

If PG is authority:

* Stytch can be swapped like Stripe → Adyen
* identities stay put
* sessions are ephemeral

Vendor lock-in isn’t binary—but authority *amplifies* it.

---

## 6. Cross-product identity (lost)

You’re building **Creator Vortex**, but you’ve already hinted this identity substrate wants to serve:

* future creator tools
* ops/admin tools
* maybe other Racoon Works ventures

If Stytch is authority:

* identity is scoped to a *project*
* cross-product identity becomes brittle or duplicated

If PG is authority:

* identity is global
* products become views

This is a huge architectural fork.

---

## 7. Regulation-as-product optionality (lost)

If identity lives in PG, you can later:

* expose audit trails
* sell compliance exports
* do forensic reconstruction
* build trust tooling

If identity lives in Stytch:

* you depend on their logs
* their retention
* their interpretation of events

That caps your ability to **productize trust** later.

(And per your standing rule: yes, this is exactly where SaaS opportunities tend to hide.)

---

## What you *gain* by making Stytch authority (to be fair)

You do gain real things:

* faster MVP
* fewer tables
* fewer edge cases early
* fewer auth bugs
* easier support in year 0

For many SaaS products, that trade is correct.

The question is not “is it bad?”
It’s “is it aligned with where you’re clearly going?”

---

## The honest recommendation (given *you*)

Given:

* your ledger instincts (TigerBeetle, auditability)
* your desire for sovereignty
* your multi-product horizon
* your explicit framing of PG as truth elsewhere

**I would not make Stytch authority.**

I would:

* treat Stytch as **credential oracle + session mint**
* bind identities explicitly
* keep PG as the identity ledger
* accept slightly more work now for vastly more freedom later

That doesn’t mean *anti-Stytch*.
It means **Stytch as a pure function**, not a state machine you don’t own.

---

## The invariant to remember

> **Who exists is more fundamental than how they prove it.**

Once you outsource *existence*, getting it back is hard.