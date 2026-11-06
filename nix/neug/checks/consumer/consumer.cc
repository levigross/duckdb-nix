// A program that uses an installed NeuG the way a user's would: found through its CMake
// package, linked against libneug, loading the extensions it is given by name (no INSTALL),
// and asking a graph a question that takes two hops. Anything unexpected is a non-zero exit.
#include <neug/neug.h>

#include <cstdlib>
#include <iostream>
#include <string>

static neug::QueryResult run(neug::Connection& conn, const std::string& query) {
  auto result = conn.Query(query);
  if (!result) {
    std::cerr << "query failed: " << query << ": " << result.error().ToString() << "\n";
    std::exit(1);
  }
  return std::move(result).value();
}

int main(int argc, char** argv) {
  neug::NeugDB db;
  if (!db.Open("")) {  // in memory
    std::cerr << "cannot open a database\n";
    return 2;
  }
  auto conn = db.Connect();
  std::cout << "NeuG " << db.Version() << "\n";

  for (int i = 1; i < argc; ++i) {
    auto loaded = conn->Query(std::string("LOAD ") + argv[i]);
    if (!loaded) {
      std::cerr << "LOAD " << argv[i] << " failed: " << loaded.error().ToString() << "\n";
      return 1;
    }
    std::cout << "loaded " << argv[i] << "\n";
  }
  if (argc > 1) {
    std::cout << run(*conn, "CALL SHOW_LOADED_EXTENSIONS() RETURN *").ToString() << "\n";
  }

  run(*conn, "CREATE NODE TABLE person(id INT64, name STRING, age INT64, PRIMARY KEY(id));");
  run(*conn, "CREATE REL TABLE knows(FROM person TO person);");
  run(*conn, "CREATE (:person {id: 1, name: 'Alice', age: 30});");
  run(*conn, "CREATE (:person {id: 2, name: 'Bob', age: 25});");
  run(*conn, "CREATE (:person {id: 3, name: 'Carol', age: 41});");
  run(*conn, "MATCH (a:person {id: 1}), (b:person {id: 2}) CREATE (a)-[:knows]->(b);");
  run(*conn, "MATCH (a:person {id: 2}), (b:person {id: 3}) CREATE (a)-[:knows]->(b);");

  auto friends = run(
      *conn,
      "MATCH (a:person {id: 1})-[:knows]->(b:person)-[:knows]->(c:person) RETURN c.name;");
  if (friends.length() != 1) {
    std::cerr << "expected one friend of a friend, got " << friends.length() << "\n";
    return 1;
  }
  // the cursor starts on the first row: a row is read, and then next() moves on
  if (!friends.hasNext()) {
    std::cerr << "no row to read\n";
    return 1;
  }
  std::cout << "friend of a friend of Alice: " << friends.GetString(0) << "\n";
  if (friends.GetString(0) != "Carol") {
    return 1;
  }

  // a query of a table that does not exist is an error, not an empty answer
  auto wrong = conn->Query("MATCH (n:no_such_table) RETURN n;");
  if (wrong) {
    std::cerr << "a query of a table that does not exist did not fail\n";
    return 1;
  }
  std::cout << "a wrong query is an error: " << wrong.error().ToString() << "\n";

  db.Close();
  return 0;
}
