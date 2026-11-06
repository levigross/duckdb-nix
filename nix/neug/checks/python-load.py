"""LOAD one extension in an in-memory database; the exit status says whether it worked.

    python-load.py <extension>
"""

import sys

import neug

# the database is held while the connection is used: closing it closes the connection
db = neug.Database("", mode="w")
conn = db.connect()
conn.execute(f"LOAD {sys.argv[1]}")
conn.close()
db.close()
