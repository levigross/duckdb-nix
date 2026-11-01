#define DUCKDB_EXTENSION_MAIN

#include "hello_extension.hpp"
#include "duckdb.hpp"
#include "duckdb/function/scalar_function.hpp"

namespace duckdb {

// hello(name) is 'Hello, <name>!', and NULL for a NULL name
static void HelloScalarFun(DataChunk &args, ExpressionState &state, Vector &result) {
	UnaryExecutor::Execute<string_t, string_t>(args.data[0], result, args.size(), [&](string_t name) {
		return StringVector::AddString(result, "Hello, " + name.GetString() + "!");
	});
}

static void LoadInternal(ExtensionLoader &loader) {
	loader.RegisterFunction(ScalarFunction("hello", {LogicalType::VARCHAR}, LogicalType::VARCHAR, HelloScalarFun));
}

void HelloExtension::Load(ExtensionLoader &loader) {
	LoadInternal(loader);
}

std::string HelloExtension::Name() {
	return "hello";
}

// The version that extension.nix gives to mkExtension
std::string HelloExtension::Version() const {
#ifdef EXT_VERSION_HELLO
	return EXT_VERSION_HELLO;
#else
	return "";
#endif
}

} // namespace duckdb

extern "C" {

DUCKDB_CPP_EXTENSION_ENTRY(hello, loader) {
	duckdb::LoadInternal(loader);
}
}
