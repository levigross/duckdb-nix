"""The service mode of NeuG through its Python module: a database is served over HTTP, a query
is asked with a plain HTTP request (the payload and the answer are those of the client of the
module, Session, but the request is made here), the answer is compared, and the server is
stopped. The process must end by itself with status 0: the check that runs this puts a time limit
on it, so that a crash or a hang fails.

The server is not the one of upstream's Linux build (brpc) but NeuG's second transport,
cpp-httplib, so what the clients rely on is asked of it here:

  - a path with an empty segment (a client given "http://host:port/" asks "//cypher") is
    routed like the path without it, as brpc does;
  - a request on a connection that is kept is answered at once: 200 of them take well under a
    second, where a server that writes the head and the body of the answer as two segments and
    waits for the acknowledgement of the first (Nagle's algorithm against the delayed ACK of the
    client) needs 25 ms for each.

    python-serve.py serve        serve a database on a free port, ask it, stop it
    python-serve.py ask <uri>    ask the server at <uri> and compare the answer (it must fail
                                 where nothing listens)
"""

import os
import socket
import sys
import tempfile
import time

import requests
from neug import Database
from neug.query_result import QueryResult
from neug_py_bind import PyQueryRequest, PyQueryResult

FRIEND_OF_A_FRIEND = (
    "MATCH (a:person {id: 1})-[:knows]->(:person)-[:knows]->(c:person) RETURN c.name;"
)

# requests on one connection, and the time they may take: about 0.1 s with the transport as it
# should be, 5 s with the one that waits for an acknowledgement
REQUESTS_IN_A_ROW = 200
SECONDS_FOR_THEM = 2.5


def ask(uri, query):
    """The rows that the server at <uri> answers to <query>, by two HTTP requests."""
    status = requests.get(f"{uri}/service_status", timeout=10)
    status.raise_for_status()

    response = requests.post(
        f"{uri}/cypher",
        data=PyQueryRequest.serialize_request(query, ""),
        timeout=30,
    )
    assert response.status_code == 200, (response.status_code, response.text)
    return [list(row) for row in QueryResult(PyQueryResult(response.content))]


def free_port():
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]


def what_clients_rely_on(uri):
    """The things that differ between the servers, as a list of what is wrong (empty if none)."""
    wrong = []
    payload = PyQueryRequest.serialize_request(FRIEND_OF_A_FRIEND, "")

    # an endpoint given with a trailing slash makes a path that starts with two
    answer = requests.post(f"{uri}//cypher", data=payload, timeout=10)
    if answer.status_code != 200:
        wrong.append(f"POST //cypher answered {answer.status_code}, not 200")
    answer = requests.get(f"{uri}//service_status", timeout=10)
    if answer.status_code != 200:
        wrong.append(f"GET //service_status answered {answer.status_code}, not 200")
    answer = requests.get(f"{uri}//transactions", timeout=10)
    if answer.status_code != 405 or answer.headers.get("Allow") != "POST":
        wrong.append(
            f"GET //transactions answered {answer.status_code} (Allow: "
            f"{answer.headers.get('Allow')}), not 405 (Allow: POST)"
        )

    session = requests.Session()
    start = time.perf_counter()
    for _ in range(REQUESTS_IN_A_ROW):
        answer = session.post(f"{uri}/cypher", data=payload, timeout=10)
        assert answer.status_code == 200, answer.status_code
    took = time.perf_counter() - start
    print(f"{REQUESTS_IN_A_ROW} requests on one connection took {took:.2f} s")
    if took >= SECONDS_FOR_THEM:
        wrong.append(
            f"{REQUESTS_IN_A_ROW} requests on one connection took {took:.2f} s, "
            f"the limit is {SECONDS_FOR_THEM} s"
        )
    return wrong


def serve():
    db = Database(os.path.join(tempfile.mkdtemp(), "db"), mode="w")
    conn = db.connect()
    conn.execute("CREATE NODE TABLE person(id INT64, name STRING, PRIMARY KEY(id));")
    conn.execute("CREATE REL TABLE knows(FROM person TO person);")
    for id_, name in [(1, "Alice"), (2, "Bob"), (3, "Carol")]:
        conn.execute(f"CREATE (:person {{id: {id_}, name: '{name}'}});")
    conn.execute("MATCH (a:person {id: 1}), (b:person {id: 2}) CREATE (a)-[:knows]->(b);")
    conn.execute("MATCH (a:person {id: 2}), (b:person {id: 3}) CREATE (a)-[:knows]->(b);")
    # the server wants no local connection open
    conn.close()

    port = free_port()
    uri = db.serve(port, "127.0.0.1", False)
    print(f"serving at {uri}", flush=True)
    wrong = []
    try:
        rows = ask(uri, FRIEND_OF_A_FRIEND)
        assert rows == [["Carol"]], rows
        print(f"the server answers over HTTP: friend of a friend of Alice is {rows[0][0]}")

        # a query that is wrong comes back as an error, and the server stays up
        answer = requests.post(
            f"{uri}/cypher",
            data=PyQueryRequest.serialize_request("MATCH (n:no_such_table) RETURN n;", ""),
            timeout=30,
        )
        assert answer.status_code != 200, "a query of a table that does not exist was answered"
        assert ask(uri, FRIEND_OF_A_FRIEND) == [["Carol"]]

        wrong = what_clients_rely_on(uri)
    finally:
        db.stop_serving()
        db.close()
    print("stopped")

    # reported after the server is stopped, all of them, so that each shows
    if wrong:
        raise SystemExit("the server differs from what its clients rely on:\n  " + "\n  ".join(wrong))


def main():
    if sys.argv[1:] == ["serve"]:
        serve()
    elif len(sys.argv) == 3 and sys.argv[1] == "ask":
        rows = ask(sys.argv[2], FRIEND_OF_A_FRIEND)
        assert rows == [["Carol"]], rows
    else:
        raise SystemExit(__doc__)


if __name__ == "__main__":
    main()
