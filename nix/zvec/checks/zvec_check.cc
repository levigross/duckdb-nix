// A program that uses the libraries of zvec the way the vector_search extension of NeuG does:
// it makes an index (a flat one, which is exact, and an HNSW one), puts 1000 vectors of 8
// dimensions in it, and asks for the nearest ones of three of them. Anything that is not as
// it must be is a non-zero exit.
#include <roaring.hh>
#include <zvec/core/framework/index_logger.h>
#include <zvec/core/interface/index.h>
#include <zvec/core/interface/index_factory.h>

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <filesystem>
#include <functional>
#include <random>
#include <vector>

using namespace zvec::core_interface;
#define CHECK(c)                                                       \
  do {                                                                 \
    if (!(c)) {                                                        \
      std::fprintf(stderr, "FAIL %s:%d: %s\n", __FILE__, __LINE__, #c); \
      std::exit(1);                                                    \
    }                                                                  \
  } while (0)

constexpr size_t kN = 1000, kDim = 8, kK = 10;
static std::vector<float> g_data;
using QueryMaker = std::function<std::shared_ptr<BaseIndexQueryParam>()>;

static float l2sq(size_t a, size_t b) {
  float s = 0;
  for (size_t d = 0; d < kDim; ++d) {
    float x = g_data[a * kDim + d] - g_data[b * kDim + d];
    s += x * x;
  }
  return s;
}

static VectorData row(size_t r) {
  VectorData v;
  v.vector = DenseVector{&g_data[r * kDim]};
  return v;
}

static void exercise(const BaseIndexParam &param, const std::string &path, bool exact,
                     const QueryMaker &mk) {
  auto index = IndexFactory::CreateAndInitIndex(param);  // nullptr if registrars were dropped
  CHECK(index != nullptr);
  StorageOptions so;
  so.type = StorageOptions::StorageType::kMMAP;
  so.create_new = true;
  CHECK(index->Open(path, so) == 0);
  for (size_t i = 0; i < kN; ++i) CHECK(index->Add(row(i), 1000 + i) == 0);
  // Not asserted: the flat index reports twice what was added. That it is not stored twice
  // is what the searches below show, which would return a vector twice.
  std::printf("%zu vectors added, GetDocCount() says %u\n", kN, index->GetDocCount());
  for (size_t q : {0, 417, 999}) {
    SearchResult res;
    CHECK(index->Search(row(q), mk(), &res) == 0);
    const auto &d = res.doc_list_;
    CHECK(d.size() == kK);
    CHECK(d[0].key() == 1000 + q && std::fabs(d[0].score()) < 1e-5f);  // itself, distance 0
    std::vector<float> all;
    for (size_t j = 0; j < kN; ++j) all.push_back(l2sq(q, j));
    std::partial_sort(all.begin(), all.begin() + kK, all.end());
    for (size_t i = 0; i < d.size(); ++i) {
      CHECK(std::fabs(d[i].score() - l2sq(q, d[i].key() - 1000)) < 1e-4f);  // the distance is right
      CHECK(i == 0 || d[i - 1].score() <= d[i].score());                    // ascending
      CHECK(!exact || std::fabs(d[i].score() - all[i]) < 1e-4f);            // flat == brute force
    }
  }
  // A roaring bitmap as a filter (the predicate returns true to EXCLUDE). Last, since the
  // context of the flat index keeps the filter.
  auto allowed = std::make_shared<roaring::Roaring>();
  for (uint32_t i = 0; i < kN; i += 3) allowed->add(1000 + i);
  auto fq = mk();
  fq->filter = std::make_shared<IndexFilter>();
  fq->filter->set([allowed](uint64_t k) { return !allowed->contains(static_cast<uint32_t>(k)); });
  SearchResult res;
  CHECK(index->Search(row(1), fq, &res) == 0 && !res.doc_list_.empty());  // row 1 is excluded
  for (const auto &doc : res.doc_list_) CHECK((doc.key() - 1000) % 3 == 0);
  CHECK(index->Close() == 0);
}

int main() {
  zvec::core::IndexLoggerBroker::SetLevel(zvec::core::IndexLogger::LEVEL_WARN);
  // the registry of the framework: empty if the components that register themselves were left
  // out of the program by the linker
  using F = zvec::core::IndexFactory;
  CHECK(F::HasMetric("SquaredEuclidean") && F::HasStorage("MMapFileStorage") &&
        F::HasStreamer("FlatStreamer") && F::HasStreamer("HnswStreamer"));

  std::mt19937 rng(42);
  std::uniform_real_distribution<float> u(0.f, 1.f);
  g_data.resize(kN * kDim);
  for (auto &x : g_data) x = u(rng);
  auto dir = std::filesystem::temp_directory_path() / "zvec-check";
  std::filesystem::remove_all(dir);
  std::filesystem::create_directories(dir);

  FlatIndexParam flat;
  flat.metric_type = MetricType::kL2sq;
  flat.dimension = kDim;
  flat.data_type = DataType::DT_FP32;
  exercise(flat, (dir / "flat.idx").string(), true, [] {
    auto q = std::make_shared<FlatQueryParam>();
    q->topk = kK;
    return q;
  });

  HNSWIndexParam hnsw(MetricType::kL2sq, kDim, 16, 200);
  hnsw.data_type = DataType::DT_FP32;
  exercise(hnsw, (dir / "hnsw.idx").string(), false, [] {
    auto q = std::make_shared<HNSWQueryParam>();
    q->topk = kK;
    q->ef_search = 200;
    return q;
  });

  std::filesystem::remove_all(dir);
  std::puts("zvec check OK");
}
