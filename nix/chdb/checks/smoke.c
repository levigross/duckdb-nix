// A program that links libchdb. With --version it prints the version of the library. With
// anything else it starts the engine, runs the query it is given (with none, one that sums
// 1..100), writes the result to stdout, and on an error writes it to stderr and exits with 1.
#include <chdb.h>
#include <stdio.h>
#include <string.h>

int main(int argc, char **argv) {
  if (argc > 1 && strcmp(argv[1], "--version") == 0) {
    puts(chdb_version());
    return 0;
  }

  const char *query = argc > 1 ? argv[1] : "SELECT sum(number + 1) FROM numbers(100)";
  char *args[] = {"smoke", NULL};

  chdb_connection *conn = chdb_connect(1, args);
  if (!conn) {
    fprintf(stderr, "chdb_connect failed\n");
    return 2;
  }

  chdb_result *result = chdb_query(*conn, query, "CSV");
  const char *error = chdb_result_error(result);
  if (error) {
    fprintf(stderr, "%s\n", error);
    chdb_destroy_query_result(result);
    chdb_close_conn(conn);
    return 1;
  }

  fwrite(chdb_result_buffer(result), 1, chdb_result_length(result), stdout);
  chdb_destroy_query_result(result);
  chdb_close_conn(conn);
  return 0;
}
