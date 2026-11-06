"""NeuG through its Python module: an in-memory database, the extensions it is given loaded by
name from the prefix of the library, a graph and a two-hop question, and a wrong query that
must raise.

    python-smoke.py <extension home> <extension>...
"""

import os
import sys

import neug
from neug import Database

expected_home, *extensions = sys.argv[1:]

# LOAD looks where the module says, and it says the prefix of the library, unless the
# environment overrides it: the default of the package was patched to that
home = os.environ["NEUG_EXTENSION_HOME_PYENV"]
assert home == expected_home, f"extension home is {home}, expected {expected_home}"

db = Database("", mode="w")
conn = db.connect()

for name in extensions:
    conn.execute(f"LOAD {name}")
    print(f"loaded {name}")

shown = {row[0].lower() for row in conn.execute("CALL SHOW_LOADED_EXTENSIONS() RETURN *") if row[0]}
for name in extensions:
    if name != "httpfs":  # an extension of the virtual file system: it is not listed
        assert name in shown, f"{name} is not among the loaded extensions: {sorted(shown)}"

conn.execute("CREATE NODE TABLE person(id INT64, name STRING, age INT64, PRIMARY KEY(id));")
conn.execute("CREATE REL TABLE knows(FROM person TO person);")
conn.execute("CREATE (:person {id: 1, name: 'Alice', age: 30});")
conn.execute("CREATE (:person {id: 2, name: 'Bob', age: 25});")
conn.execute("CREATE (:person {id: 3, name: 'Carol', age: 41});")
conn.execute("MATCH (a:person {id: 1}), (b:person {id: 2}) CREATE (a)-[:knows]->(b);")
conn.execute("MATCH (a:person {id: 2}), (b:person {id: 3}) CREATE (a)-[:knows]->(b);")

people = list(conn.execute("MATCH (n:person) RETURN n.id, n.name, n.age ORDER BY n.id;"))
assert len(people) == 3, people
assert people[0][0] == 1 and people[0][1] == "Alice", people[0]

friends = list(
    conn.execute(
        "MATCH (a:person {id: 1})-[:knows]->(:person)-[:knows]->(c:person) RETURN c.name;"
    )
)
assert len(friends) == 1 and friends[0][0] == "Carol", friends
print(f"friend of a friend of Alice: {friends[0][0]}")

try:
    conn.execute("MATCH (n:no_such_table) RETURN n;")
except Exception as error:  # the type is the module's own
    print(f"a wrong query raises: {type(error).__name__}")
else:
    raise SystemExit("a query of a table that does not exist did not raise")

conn.close()
db.close()
print(f"neug python OK, version {neug.__version__}")
