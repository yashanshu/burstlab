# BurstLab: the problem

**Purpose:** the input to your concept track and its exit test. Solve this yourself,
then diff your solution against `burstlab_15k_aws_beginner_course.md` and explain
every difference. Do not read the course while solving.

**Written:** 19 August 2026

## The brief

You are the backend engineer for a small analytics product. Customers send you
events from their own servers. Today a single API writes each event straight into
PostgreSQL. The service is fine at 200 requests per second and falls over at 2,000:
the database saturates, response times climb past 30 seconds, and clients start
retrying, which makes the load worse.

Your task is to design, build, deploy, and load-test a replacement ingestion path.

## Functional requirements

1. Accept one JSON event per HTTP request over a network endpoint.
2. Authenticate each request. Reject unauthenticated requests.
3. Validate each event before accepting it. Reject oversized or malformed bodies.
4. Store every accepted event in PostgreSQL exactly once, even though clients and
   internal components retry.
5. Never lose an event that the API told the client it had accepted.
6. Never claim to have accepted an event you cannot later produce.

## Non-functional requirements

7. Sustain 15,000 accepted requests per second for ten continuous minutes.
8. Keep the p95 response time under 150 ms during that hold.
9. Keep failed requests under 0.5% of the total.
10. Absorb a burst that arrives faster than PostgreSQL can commit, without
    dropping accepted events and without letting response time track database
    write time.
11. After traffic stops, finish all outstanding work within 30 minutes.

## Constraints

12. Run on AWS in one Region. Use one PostgreSQL database, single-AZ.
13. Create every resource from infrastructure as code. Manual console changes are
    a failure.
14. No component may be reachable from the public internet: not the endpoint, not
    the application port, not the database, not the administrative access path.
15. No long-lived SSH keys and no long-lived cloud access keys.
16. Each component gets only the permissions it needs. A component that only
    produces work must not be able to consume it, and vice versa.
17. No plaintext credential may exist in source, in infrastructure code, or on a
    component that does not need it.
18. Expected total cost $5-10 for one capstone run. Hard stop at $20. The whole
    system must be destroyable, and verifiably destroyed, in one session.
19. Per-request logging is not affordable at this rate. You must still be able to
    verify what happened.
20. Synthetic data only. No customer data enters this system.

## What you must produce

- The architecture, with a defence of every component you added.
- The correctness rules that make requirement 4, 5, and 6 true together, stated
  as invariants that hold under crash.
- Working application code and infrastructure code.
- A load generator, and the arithmetic that says your generator can produce
  15,000 RPS without becoming the bottleneck.
- A written cost plan and a teardown procedure.
- A results statement: what your test proved, and an explicit list of what it did
  not prove.

## Acceptance criteria

You have solved this when all of the following are true after one run:

- aggregate offered load reached 15,000 RPS;
- the ten-minute hold completed, or you recorded a stated stop condition;
- your load generator dropped zero iterations;
- failed requests stayed under 0.5%;
- p95 stayed under 150 ms;
- the count of rows in PostgreSQL equals the count of unique accepted requests;
- no accepted event is unaccounted for;
- all outstanding work finished within 30 minutes of traffic stopping;
- total spend stayed under $20;
- every billable resource is destroyed and you can show that it is.

## Questions this problem will ask you

Answer these without the course open. They are the teaching test, not a checklist.

1. Where does the client's request stop being your problem and start being
   durable? What exactly have you promised at that moment?
2. What happens to an event if a component crashes at the worst possible instant?
   Name the instant.
3. Why is your throughput number not simply "the database's write rate"?
4. What is the smallest change to your design that would silently lose data?
5. What does your 15,000 RPS result entitle you to say to a customer?
