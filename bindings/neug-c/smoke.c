/* A C program that uses the interface the way a binding does: it opens a database in memory,
 * makes a graph, asks a question that takes two hops, reads every type it can, and takes the
 * paths that fail: a wrong query, a getter of the wrong type, a NULL, a second connection, a
 * transaction that is rolled back, an extension that does not exist. Anything unexpected is a
 * non-zero exit. Extensions named on the command line are loaded first. */
#include "neug_c.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define CHECK(c)                                                         \
  do {                                                                   \
    if (!(c)) {                                                          \
      fprintf(stderr, "FAIL %s:%d: %s\n", __FILE__, __LINE__, #c);       \
      exit(1);                                                           \
    }                                                                    \
  } while (0)

static neug_conn* conn;

static neug_result* run(const char* cypher) {
  neug_result* result = NULL;
  neug_error* err = NULL;
  int32_t status = neug_conn_query(conn, cypher, NEUG_ACCESS_INFER, NULL, &result, &err);
  if (status != NEUG_OK) {
    fprintf(stderr, "query failed: %s: %d %s\n", cypher, status, neug_error_message(err));
    exit(1);
  }
  return result;
}

static size_t count(const char* cypher) {
  neug_result* result = run(cypher);
  size_t rows = neug_result_rows(result);
  neug_result_free(result);
  return rows;
}

int main(int argc, char** argv) {
  CHECK(neug_c_abi_version() == NEUG_C_ABI_VERSION);
  printf("neug_c for NeuG %s\n", neug_c_version());

  neug_open_options options;
  neug_open_options_init(&options);
  neug_db* db = NULL;
  neug_error* err = NULL;
  CHECK(neug_db_open(&options, &db, &err) == NEUG_OK);
  CHECK(neug_conn_open(db, &conn, &err) == NEUG_OK);

  /* one connection to a database that is read and written */
  neug_conn* second = NULL;
  /* the engine throws for it, so it is an exception whose text ends with the code of NeuG */
  CHECK(neug_conn_open(db, &second, &err) == NEUG_E_EXCEPTION && second == NULL);
  CHECK(strstr(neug_error_message(err), "Error Code: 4001") != NULL);
  printf("a second connection: %s\n", neug_error_message(err));
  neug_error_free(err);
  err = NULL;

  for (int i = 1; i < argc; ++i) {
    neug_result* result = NULL;
    char query[256];
    snprintf(query, sizeof query, "LOAD %s", argv[i]);
    int32_t status = neug_conn_query(conn, query, NEUG_ACCESS_INFER, NULL, &result, &err);
    if (status != NEUG_OK) {
      fprintf(stderr, "LOAD %s failed: %s\n", argv[i], neug_error_message(err));
      return 1;
    }
    neug_result_free(result);
    printf("loaded %s\n", argv[i]);
  }

  /* an extension that does not exist is an error, with a message */
  {
    neug_result* result = NULL;
    CHECK(neug_conn_query(conn, "LOAD no_such_extension", NEUG_ACCESS_INFER, NULL, &result,
                          &err) != NEUG_OK);
    CHECK(result == NULL && err != NULL);
    neug_error_free(err);
    err = NULL;
  }

  neug_result_free(run("CREATE NODE TABLE person(id INT64, name STRING, age INT64, "
                       "score DOUBLE, ok BOOL, PRIMARY KEY(id));"));
  neug_result_free(run("CREATE REL TABLE knows(FROM person TO person);"));
  neug_result_free(run("CREATE (:person {id: 1, name: 'Alice', age: 30, score: 1.5, ok: true});"));
  neug_result_free(run("CREATE (:person {id: 2, name: 'Bob', age: 25, score: 2.5, ok: false});"));
  neug_result_free(run("CREATE (:person {id: 3, name: 'Carol', age: 41, score: 3.5, ok: true});"));
  /* a person with no age: a NULL */
  neug_result_free(run("CREATE (:person {id: 4, name: 'Dan'});"));
  neug_result_free(run("MATCH (a:person {id: 1}), (b:person {id: 2}) CREATE (a)-[:knows]->(b);"));
  neug_result_free(run("MATCH (a:person {id: 2}), (b:person {id: 3}) CREATE (a)-[:knows]->(b);"));

  /* two hops */
  neug_result* hops = run("MATCH (a:person {id: 1})-[:knows]->(:person)-[:knows]->(c:person) "
                          "RETURN c.name, c.age;");
  CHECK(neug_result_rows(hops) == 1 && neug_result_columns(hops) == 2);
  printf("columns: '%s' '%s'\n", neug_result_column_name(hops, 0), neug_result_column_name(hops, 1));
  /* the engine names a column with the number of its variable in front: _7_c.name */
  CHECK(strstr(neug_result_column_name(hops, 0), "c.name") != NULL);
  CHECK(neug_result_column_type(hops, 0) == NEUG_T_STRING);
  CHECK(neug_result_column_type(hops, 1) == NEUG_T_INT64);
  CHECK(neug_result_step(hops) == 1);
  const char* text = NULL;
  size_t length = 0;
  CHECK(neug_result_get_string(hops, 0, &text, &length, &err) == NEUG_OK);
  CHECK(length == 5 && memcmp(text, "Carol", 5) == 0);
  int64_t age = 0;
  CHECK(neug_result_get_i64(hops, 1, &age, &err) == NEUG_OK && age == 41);
  CHECK(neug_result_step(hops) == 0); /* the end */
  printf("friend of a friend of Alice: %.*s, %lld\n", (int)length, text, (long long)age);

  /* every row, every type, a NULL, and the getters that do not fit */
  neug_result* people = run("MATCH (n:person) RETURN n.id, n.name, n.age, n.score, n.ok "
                            "ORDER BY n.id;");
  CHECK(neug_result_rows(people) == 4);
  CHECK(neug_result_column_type(people, 3) == NEUG_T_DOUBLE);
  CHECK(neug_result_column_type(people, 4) == NEUG_T_BOOL);
  size_t seen = 0;
  double total = 0;
  while (neug_result_step(people)) {
    int64_t id = 0;
    CHECK(neug_result_get_i64(people, 0, &id, &err) == NEUG_OK && (size_t)id == seen + 1);
    /* A person made without these properties (id 4) does not have NULLs: the engine gives the
     * default of the type, 0, 0.0 and false. */
    CHECK(neug_result_get_i64(people, 2, &age, &err) == NEUG_OK);
    CHECK(age == (id == 1 ? 30 : id == 2 ? 25 : id == 3 ? 41 : 0));
    double score = -1;
    CHECK(neug_result_get_f64(people, 3, &score, &err) == NEUG_OK);
    total += score;
    uint8_t ok = 2;
    CHECK(neug_result_get_bool(people, 4, &ok, &err) == NEUG_OK);
    CHECK(ok == (id == 1 || id == 3));
    int32_t flag = 1;
    CHECK(neug_result_is_null(people, 2, &flag, &err) == NEUG_OK && flag == 0);
    ++seen;
  }
  CHECK(seen == 4 && total == 1.5 + 2.5 + 3.5);
  /* the cursor is past the end: a getter says so */
  CHECK(neug_result_get_i64(people, 0, &age, &err) == NEUG_E_NO_ROW);
  neug_error_free(err);
  err = NULL;
  neug_result_rewind(people);
  CHECK(neug_result_step(people) == 1);
  float f = 0;
  CHECK(neug_result_get_f32(people, 1, &f, &err) == NEUG_E_TYPE); /* a string as a float */
  printf("a string read as a float: %s\n", neug_error_message(err));
  neug_error_free(err);
  err = NULL;
  CHECK(neug_result_get_i64(people, 99, &age, &err) == NEUG_E_COLUMN);
  neug_error_free(err);
  err = NULL;
  neug_result_free(people);
  neug_result_free(hops);

  /* A NULL is what an OPTIONAL MATCH that finds nothing gives */
  {
    neug_result* none = run("OPTIONAL MATCH (n:person {id: 77}) RETURN n.name, n.age;");
    CHECK(neug_result_rows(none) == 1 && neug_result_step(none) == 1);
    int32_t flag = 0;
    CHECK(neug_result_is_null(none, 0, &flag, &err) == NEUG_OK && flag == 1);
    CHECK(neug_result_get_string(none, 0, &text, &length, &err) == NEUG_NULL);
    CHECK(neug_result_get_i64(none, 1, &age, &err) == NEUG_NULL);
    neug_result_free(none);
  }

  /* parameters */
  {
    neug_result* result = NULL;
    CHECK(neug_conn_query(conn, "MATCH (n:person) WHERE n.id = $id RETURN n.name;",
                          NEUG_ACCESS_READ, "{\"id\": 2}", &result, &err) == NEUG_OK);
    CHECK(neug_result_step(result) == 1);
    CHECK(neug_result_get_string(result, 0, &text, &length, &err) == NEUG_OK);
    CHECK(length == 3 && memcmp(text, "Bob", 3) == 0);
    neug_result_free(result);
    CHECK(neug_conn_query(conn, "RETURN 1;", NEUG_ACCESS_READ, "[1, 2]", &result, &err) ==
          NEUG_E_PARAMETERS);
    neug_error_free(err);
    err = NULL;
  }

  /* a transaction that is rolled back leaves nothing */
  CHECK(neug_conn_in_transaction(conn) == 0);
  CHECK(neug_conn_begin(conn, 0, &err) == NEUG_OK);
  CHECK(neug_conn_in_transaction(conn) == 1);
  neug_result_free(run("CREATE (:person {id: 9, name: 'Zed', age: 1});"));
  CHECK(count("MATCH (n:person {id: 9}) RETURN n.id;") == 1); /* seen inside */
  CHECK(neug_conn_rollback(conn, &err) == NEUG_OK);
  CHECK(neug_conn_in_transaction(conn) == 0);
  CHECK(count("MATCH (n:person {id: 9}) RETURN n.id;") == 0);
  /* and one that is committed stays */
  CHECK(neug_conn_begin(conn, 0, &err) == NEUG_OK);
  neug_result_free(run("CREATE (:person {id: 10, name: 'Kim', age: 2});"));
  CHECK(neug_conn_commit(conn, &err) == NEUG_OK);
  CHECK(count("MATCH (n:person {id: 10}) RETURN n.id;") == 1);

  /* a wrong query is an error with NeuG's own code and a message that says what */
  {
    neug_result* result = NULL;
    int32_t status = neug_conn_query(conn, "MATCH (n:no_such_table) RETURN n;", NEUG_ACCESS_INFER,
                                     NULL, &result, &err);
    CHECK(status != NEUG_OK && status < 10000 && result == NULL && err != NULL);
    CHECK(neug_error_code(err) == status);
    CHECK(strstr(neug_error_message(err), "no_such_table") != NULL);
    printf("a wrong query: %d\n", status);
    neug_error_free(err);
    err = NULL;
  }

  neug_conn_free(conn);
  CHECK(neug_db_close(db, &err) == NEUG_OK);
  neug_db_free(db);
  puts("neug_c smoke OK");
  return 0;
}
