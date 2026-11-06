/* Two embedded engines in one process: chDB (ClickHouse, libchdb) and NeuG (through its C
 * interface). Each brings its own copies of the libraries it is made of (protobuf, abseil,
 * glog and more) and its own allocator, and the question is whether they leave each other
 * alone: the symbols of one bound to the code of the other, the extensions of NeuG loaded with
 * dlopen beside the code of chDB, two threads each in one engine.
 *
 * Usage: coexist chdb-first|neug-first [extension ...]
 * The order says which engine is started first. The extensions are loaded into NeuG between
 * queries of chDB. Anything not as expected is a non-zero exit. */
#include <chdb.h>
#include <neug_c.h>

#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define CHECK(c)                                                       \
  do {                                                                 \
    if (!(c)) {                                                        \
      fprintf(stderr, "FAIL %s:%d: %s\n", __FILE__, __LINE__, #c);     \
      exit(1);                                                         \
    }                                                                  \
  } while (0)

static chdb_connection* chdb;
static neug_db* ng_db;
static neug_conn* ng_conn;

static void chdb_start(void) {
  char* args[] = {"coexist", NULL};
  chdb = chdb_connect(1, args);
  CHECK(chdb != NULL);
}

static void neug_start(void) {
  neug_open_options options;
  neug_open_options_init(&options);
  neug_error* err = NULL;
  CHECK(neug_db_open(&options, &ng_db, &err) == NEUG_OK);
  CHECK(neug_conn_open(ng_db, &ng_conn, &err) == NEUG_OK);
}

/* the text a query of chDB gives, without its newline; exits on an error */
static void chdb_text(const char* sql, char* out, size_t size) {
  chdb_result* result = chdb_query(*chdb, sql, "CSV");
  const char* error = chdb_result_error(result);
  if (error != NULL) {
    fprintf(stderr, "chDB: %s: %s\n", sql, error);
    exit(1);
  }
  size_t length = chdb_result_length(result);
  if (length >= size) length = size - 1;
  memcpy(out, chdb_result_buffer(result), length);
  out[length] = '\0';
  while (length > 0 && (out[length - 1] == '\n' || out[length - 1] == '\r')) out[--length] = '\0';
  chdb_destroy_query_result(result);
}

static void chdb_expect(const char* sql, const char* want) {
  char got[256];
  chdb_text(sql, got, sizeof got);
  if (strcmp(got, want) != 0) {
    fprintf(stderr, "chDB: %s: expected %s, got %s\n", sql, want, got);
    exit(1);
  }
}

static neug_result* neug_run(neug_conn* conn, const char* cypher) {
  neug_result* result = NULL;
  neug_error* err = NULL;
  if (neug_conn_query(conn, cypher, NEUG_ACCESS_INFER, NULL, &result, &err) != NEUG_OK) {
    fprintf(stderr, "NeuG: %s: %s\n", cypher, neug_error_message(err));
    exit(1);
  }
  return result;
}

static void neug_expect_one_string(neug_conn* conn, const char* cypher, const char* want) {
  neug_result* result = neug_run(conn, cypher);
  const char* text = NULL;
  size_t length = 0;
  neug_error* err = NULL;
  CHECK(neug_result_step(result) == 1);
  CHECK(neug_result_get_string(result, 0, &text, &length, &err) == NEUG_OK);
  CHECK(length == strlen(want) && memcmp(text, want, length) == 0);
  neug_result_free(result);
}

/* one thread in each engine at the same time */
static void* chdb_thread(void* arg) {
  (void)arg;
  for (int i = 0; i < 100; ++i) {
    chdb_expect("SELECT sum(number + 1) FROM numbers(100)", "5050");
  }
  return NULL;
}

static void* neug_thread(void* arg) {
  (void)arg;
  /* a connection is used by one thread; this is the one of the program, used here only */
  for (int i = 0; i < 100; ++i) {
    neug_expect_one_string(ng_conn,
                           "MATCH (a:person {id: 1})-[:knows]->(:person)-[:knows]->(c:person) "
                           "RETURN c.name;",
                           "Carol");
  }
  return NULL;
}

int main(int argc, char** argv) {
  CHECK(argc >= 2);
  const int chdb_first = strcmp(argv[1], "chdb-first") == 0;
  CHECK(chdb_first || strcmp(argv[1], "neug-first") == 0);

  /* their versions, so that a binding of these names to something else shows in the log */
  printf("chDB %s and NeuG %s (interface %u)\n", chdb_version(), neug_c_version(),
         neug_c_abi_version());

  if (chdb_first) {
    chdb_start();
    neug_start();
  } else {
    neug_start();
    chdb_start();
  }

  chdb_expect("SELECT sum(number + 1) FROM numbers(100)", "5050");
  chdb_expect("INSERT INTO FUNCTION file('coexist.parquet', Parquet) SELECT number AS n "
              "FROM numbers(1000)",
              "");

  neug_result* r = neug_run(ng_conn, "CREATE NODE TABLE person(id INT64, name STRING, "
                                     "PRIMARY KEY(id));");
  neug_result_free(r);
  neug_result_free(neug_run(ng_conn, "CREATE REL TABLE knows(FROM person TO person);"));
  neug_result_free(neug_run(ng_conn, "CREATE (:person {id: 1, name: 'Alice'});"));
  neug_result_free(neug_run(ng_conn, "CREATE (:person {id: 2, name: 'Bob'});"));
  neug_result_free(neug_run(ng_conn, "CREATE (:person {id: 3, name: 'Carol'});"));
  neug_result_free(neug_run(
      ng_conn, "MATCH (a:person {id: 1}), (b:person {id: 2}) CREATE (a)-[:knows]->(b);"));
  neug_result_free(neug_run(
      ng_conn, "MATCH (a:person {id: 2}), (b:person {id: 3}) CREATE (a)-[:knows]->(b);"));
  neug_expect_one_string(ng_conn,
                         "MATCH (a:person {id: 1})-[:knows]->(:person)-[:knows]->(c:person) "
                         "RETURN c.name;",
                         "Carol");
  printf("NeuG answered: Carol\n");

  /* each extension of NeuG is loaded with dlopen between two queries of chDB */
  for (int i = 2; i < argc; ++i) {
    char query[128];
    snprintf(query, sizeof query, "LOAD %s", argv[i]);
    neug_result_free(neug_run(ng_conn, query));
    chdb_expect("SELECT sum(number + 1) FROM numbers(100)", "5050");
    neug_expect_one_string(ng_conn,
                           "MATCH (a:person {id: 1})-[:knows]->(:person)-[:knows]->(c:person) "
                           "RETURN c.name;",
                           "Carol");
    printf("loaded %s; both engines still answer\n", argv[i]);
  }

  /* chDB reads back the Parquet file it wrote, with the Parquet code of NeuG now loaded */
  chdb_expect("SELECT sum(n) FROM file('coexist.parquet', Parquet)", "499500");

  /* and the two threads, one in each engine */
  pthread_t a, b;
  CHECK(pthread_create(&a, NULL, chdb_thread, NULL) == 0);
  CHECK(pthread_create(&b, NULL, neug_thread, NULL) == 0);
  CHECK(pthread_join(a, NULL) == 0);
  CHECK(pthread_join(b, NULL) == 0);
  printf("two threads, one in each engine: 100 queries each\n");

  neug_conn_free(ng_conn);
  neug_error* err = NULL;
  CHECK(neug_db_close(ng_db, &err) == NEUG_OK);
  neug_db_free(ng_db);
  chdb_expect("SELECT 1", "1");
  chdb_close_conn(chdb);
  puts("coexist OK");
  return 0;
}
