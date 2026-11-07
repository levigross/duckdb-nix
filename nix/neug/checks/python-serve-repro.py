import faulthandler
import os
import tempfile
import time

faulthandler.enable()

from neug import Database  # noqa: E402

d = tempfile.mkdtemp()
db = Database(db_path=os.path.join(d, "db"), mode="w")
uri = db.serve(10086, "localhost", False)
print("uri", uri, flush=True)
time.sleep(1)
print("alive", flush=True)
db.stop_serving()
db.close()
print("done", flush=True)
