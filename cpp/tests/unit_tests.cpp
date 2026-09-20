// Pure C++ checks: the SHA-256 known vectors and the worked digests of
// SPEC.md section 24, the units parser W10 is driven by, the
// dictionary codec's value types, and the affine callable's worked
// example.
#include <cstdio>
#include <iostream>
#include <limits>
#include <utility>
#include <sstream>
#include <string>
#include <vector>

#include "check.hpp"
#include "mestra/mestra.hpp"

namespace {

void sha256_vectors() {
  // The three vectors everyone checks a SHA-256 against.
  check::equal(
      "sha256 of the empty string", mestra::sha256_hex(std::string()),
      "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855");
  check::equal(
      "sha256 of \"abc\"", mestra::sha256_hex(std::string("abc")),
      "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad");
  check::equal(
      "sha256 of the 56-character vector",
      mestra::sha256_hex(std::string(
          "abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq")),
      "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1");
  // The block boundaries, where a padding mistake hides.
  check::equal(
      "sha256 of 55 a's", mestra::sha256_hex(std::string(55, 'a')),
      "9f4390f8d30c2dd92ec9f095b65e2b9ae9b0a925a5258e241c9f1e910f734318");
  check::equal(
      "sha256 of 56 a's", mestra::sha256_hex(std::string(56, 'a')),
      "b35439a4ac6f0948b6d6f9e3c6af0f5f590ce20f1bde7090ef7970686ec6738a");
  check::equal(
      "sha256 of 57 a's", mestra::sha256_hex(std::string(57, 'a')),
      "f13b2d724659eb3bf47f2dd6af1accc87b81f09f59f2b75e5c0bed6589dfe8c6");
  check::equal(
      "sha256 of 63 a's", mestra::sha256_hex(std::string(63, 'a')),
      "7d3e74a05d7db15bce4ad9ec0658ea98e3f06eeecf16b4c6fff2da457ddc2f34");
  check::equal(
      "sha256 of 64 a's", mestra::sha256_hex(std::string(64, 'a')),
      "ffe054fe7ae0cb6dc65c3af9b61d5209f439851db43d0ba5997337df154668eb");
  check::equal(
      "sha256 of 65 a's", mestra::sha256_hex(std::string(65, 'a')),
      "635361c48bb9eab14198e76ea8ab7f1a41685d6ad62aa9146d301d4f17eb0ae0");
  check::equal(
      "sha256 of 119 a's", mestra::sha256_hex(std::string(119, 'a')),
      "31eba51c313a5c08226adf18d4a359cfdfd8d2e816b13f4af952f7ea6584dcfb");
  check::equal(
      "sha256 of 120 a's", mestra::sha256_hex(std::string(120, 'a')),
      "2f3d335432c70b580af0e8e1b3674a7c020d683aa5f73aaaedfdc55af904c21c");
  check::equal(
      "sha256 of 127 a's", mestra::sha256_hex(std::string(127, 'a')),
      "c57e9278af78fa3cab38667bef4ce29d783787a2f731d4e12200270f0c32320a");
  check::equal(
      "sha256 of 128 a's", mestra::sha256_hex(std::string(128, 'a')),
      "6836cf13bac400e9105071cd6af47084dfacad4e5e302c94bfed24e013afb73e");

  // A message longer than one block, to exercise the padding.
  check::equal(
      "sha256 of a million a's",
      mestra::sha256_hex(std::string(1000000, 'a')),
      "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0");
}

void support_id_vectors() {
  // The three worked digests of section 24.
  const std::vector<std::uint8_t> types{9, 9};
  const std::vector<std::int64_t> offsets{0, 4, 8};
  const std::vector<std::int64_t> conn{0, 1, 4, 3, 1, 2, 5, 4};
  check::equal(
      "the mesh support of section 24",
      mestra::support_id_digest(6, types, offsets, conn, nullptr),
      "96df395d80ef548444562292de441525ba0b5c8ad00a8dadff19a19c943936c7");

  const std::vector<double> axis{0.0, 0.5, 1.0, 1.5};
  check::equal(
      "the axis support of section 24",
      mestra::support_id_digest(4, {}, {}, {}, &axis),
      "57467fe7370808bdb0ad01b95d963f59e8bc6762f90f96049453ae33bb05a54c");

  check::equal(
      "the support of kind none of section 24",
      mestra::support_id_digest(0, {}, {}, {}, nullptr),
      "af5570f5a1810b7af78caf4bc70a660f0df51e42baf91d4de5b2328de0e83dfc");
}

void units_parser() {
  // Everything the corpus carries must parse.
  for (const char* good : {"1", "m", "Pa", "degree", "s", "K", "W",
                           "W m-2", "m2 s-1", "m2", "m s-1", "kg m-3",
                           "W/(m2 K)", "m^2", "1e-3 m", "%"}) {
    check::is_true(std::string("units \"") + good + "\" parses",
                   mestra::units_parse(good));
  }
  // The corpus's W10 case and a few neighbours.
  for (const char* bad : {"kg/(m s", "", "m^", "(", ")", "m//s", "2m^^3"}) {
    check::is_true(std::string("units \"") + bad + "\" does not parse",
                   !mestra::units_parse(bad));
  }
  // A units string comes out of a file, so a long run of "(" must be
  // refused rather than recursed on.
  check::is_true("a deep run of parentheses is refused",
                 !mestra::units_parse(std::string(100000, '(') + "m"));
}

void codec_values() {
  mestra::Dict d;
  d.set("alpha", mestra::Value::integer(42));
  d.set("beta", mestra::Value::real(2.5));
  d.set("gamma", mestra::Value::boolean(true));
  d.set("delta", mestra::Value::text("hello"));
  d.set("epsilon", mestra::Value::null());

  mestra::Array a;
  a.dtype = mestra::DType::Float64;
  a.shape = {2, 3};
  a.f64 = {1.0, 2.0, 3.0, 4.0, 5.0, 6.0};
  d.set("zeta", mestra::Value::numbers(a));

  mestra::Array s;
  s.dtype = mestra::DType::String;
  s.shape = {2};
  s.str = {"mach", "alpha"};
  d.set("eta", mestra::Value::strings(s));

  mestra::Dict nested;
  nested.set("inner", mestra::Value::integer(7));
  d.set("theta", mestra::Value::dict(nested));

  // Section 25: an integer and a float that happen to be equal are
  // different values and stay different.
  check::is_true("an int and a float are different values",
                 !(mestra::Value::integer(2) == mestra::Value::real(2.0)));
  // A zero-dimensional array is not representable.
  bool refused = false;
  try {
    mestra::Array zero;
    zero.dtype = mestra::DType::Float64;
    zero.f64 = {1.0};
    mestra::Value::numbers(zero);
  } catch (const mestra::Error& e) {
    refused = e.rule() == "E32";
  }
  check::is_true("a zero-dimensional array is refused", refused);

  // The dump is stable and the keys come out in byte order.
  const std::string dump = mestra::dump_dict(d);
  check::is_true("the dump starts at the root",
                 dump.compare(0, 4, "D .\n") == 0);
  check::is_true("the dump holds the nested dictionary",
                 dump.find("D ./theta\n") != std::string::npos);
  check::is_true("the dump holds the null",
                 dump.find("N ./epsilon\n") != std::string::npos);
  check::is_true("the dump holds the string array",
                 dump.find("T ./eta 1 2 mach alpha\n") !=
                     std::string::npos);
  std::size_t at_alpha = dump.find("./alpha");
  std::size_t at_beta = dump.find("./beta");
  check::is_true("keys are dumped in byte order", at_alpha < at_beta);
}

void affine_worked_example() {
  // Section 27, the worked example: two keys in the order mach,
  // alpha; one scalar slot cl and one node-array slot pressure.
  mestra::AffineOutput cl;
  cl.A = {2.0, 0.1};
  cl.b = {0.05};
  cl.shape = {};

  mestra::AffineOutput pressure;
  pressure.A = {1.0, 0.0, 2.0, 0.0, 3.0, 0.5,
                4.0, 0.5, 5.0, 1.0, 6.0, 1.0};
  pressure.b = {0.0, 0.1, 0.2, 0.3, 0.4, 0.5};
  pressure.shape = {6, 1};

  std::map<std::string, mestra::AffineOutput, mestra::BytesLess> outputs;
  outputs["cl"] = cl;
  outputs["pressure"] = pressure;
  const mestra::Affine model({"mach", "alpha"}, outputs,
                             "affine(mach, alpha -> cl, pressure)");

  mestra::KeysTable table;
  table.add_column("mach", {0.5});
  table.add_column("alpha", {4.0});
  const mestra::Outputs out = model.call(table);

  check::equal("cl is 1.45 exactly", out.at("cl").f64.at(0), 1.45);
  const std::vector<double> want{0.5, 1.1, 3.7, 4.3, 6.9, 7.5};
  for (std::size_t i = 0; i < want.size(); ++i) {
    std::ostringstream what;
    what << "pressure node " << i;
    check::equal(what.str(), out.at("pressure").f64.at(i), want[i]);
  }
  check::equal("cl comes back as (1)",
               out.at("cl").shape.size(), std::size_t(1));
  check::equal("pressure comes back as (1, 6, 1)",
               out.at("pressure").shape.size(), std::size_t(3));
  check::equal("pressure names its node axis",
               out.at("pressure").dims.at(1), std::string("node"));

  // The dictionary round-trips through to_dict and from_dict.
  const mestra::Dict d = model.to_dict();
  const mestra::Affine again = mestra::Affine::from_dict(d);
  check::is_true("to_dict and from_dict agree",
                 again.to_dict() == d);
  check::equal("the type string is affine", model.type(),
               std::string("affine"));

  // A dictionary with anything else in it is refused.
  mestra::Dict extra = d;
  extra.set("seed", mestra::Value::integer(1));
  bool refused = false;
  try {
    mestra::Affine::from_dict(extra);
  } catch (const mestra::Error&) {
    refused = true;
  }
  check::is_true("an affine dictionary with an extra key is refused",
                 refused);

  // A keys table missing a column the callable declares is an error at
  // call time (section 26).
  mestra::KeysTable short_table;
  short_table.add_column("mach", {0.5});
  bool missing = false;
  try {
    model.call(short_table);
  } catch (const mestra::Error&) {
    missing = true;
  }
  check::is_true("a missing key column is an error at call time", missing);
}

// Ergonomics, checked rather than asserted: build the file of
// docs/example.md from plain vectors, write it, and see that the
// validator finds nothing to say.  If this stops reading like a
// handful of calls, the API has gone wrong.
void build_from_vectors() {
  mestra::Dataset d;
  d.writer = "mestra examples 0";
  d.created = "2026-09-19T00:00:00Z";
  d.generalisation_group = "member";

  d.add_categories("member", {"wing_a", "wing_b"});
  d.add_categories("region", {"inlet", "outlet"});

  mestra::Key& mach = d.add_key("mach", "condition", {0.40, 0.80}, "1");
  mach.lower = 0.1;
  mach.upper = 0.9;
  d.add_category_key("member", "group", {0, 1}, "member");
  d.add_scalar("cl", "1", {0.25, 0.55});

  mestra::Support& s = d.add_mesh_support(
      "s0", 6, {9, 9}, {0, 4, 8}, {0, 1, 4, 3, 1, 2, 5, 4});
  mestra::set_coordinates(
      s,
      {0.0, 0.0, 1.0, 0.0, 2.0, 0.0, 0.0, 1.0, 1.0, 1.0, 2.0, 1.0,
       0.0, 0.0, 1.5, 0.0, 3.0, 0.0, 0.0, 1.0, 1.5, 1.0, 3.0, 1.0},
      2, "m", "group:member");
  mestra::add_field(s, mestra::Location::Node, "pressure", "Pa",
                    {101, 102, 103, 104, 105, 106,
                     201, 202, 203, 204, 205, 206});
  mestra::add_label(s, mestra::Location::Cell, "region", {0, 1}, "region");

  const std::string path = "mestra_unit_built.mes";
  mestra::write(d, path);

  // The support id is filled in by the builder and is the worked one
  // of section 24.
  check::equal(
      "the builder fills in the support id", s.support_id,
      std::string(
          "96df395d80ef548444562292de441525ba0b5c8ad00a8dadff19a19c943936c7"));

  const mestra::Report report = mestra::validate(path);
  check::equal("the built file has no errors", report.errors.size(),
               std::size_t(0));
  check::equal("the built file has no warnings", report.warnings.size(),
               std::size_t(0));
  if (!report.errors.empty()) {
    for (const mestra::Finding& f : report.errors) {
      std::cout << "     " << f.id << " " << f.where << ": " << f.message
                << "\n";
    }
  }
  if (!report.warnings.empty()) {
    for (const mestra::Finding& f : report.warnings) {
      std::cout << "     " << f.id << " " << f.where << ": " << f.message
                << "\n";
    }
  }

  // Read it back and check the value docs/example.md says to check.
  const mestra::Dataset back = mestra::read(path);
  const mestra::Support* got = back.support("s0");
  check::is_true("the support comes back", got != nullptr);
  if (got != nullptr && !got->node_arrays.empty()) {
    const mestra::Array& pressure = got->node_arrays.front().data;
    check::equal("pressure names its axes by name",
                 pressure.dims.at(0) + "," + pressure.dims.at(1) + "," +
                     pressure.dims.at(2),
                 std::string("row,node,component"));
    check::equal("pressure at row 1, node 3, component 0",
                 pressure.at_f64({1, 3, 0}), 204.0);
  }
  // Section 29: opening a file must not read any array.
  const mestra::Dataset header = mestra::read_header(path);
  check::equal("a header read still states the row count", header.n_rows,
               std::int64_t(2));
  check::equal("a header read still states the support id",
               header.supports.at(0).support_id, s.support_id);
  check::is_true("a header read reads no key values",
                 header.keys.at(0).f64.empty());
  check::is_true("a header read reads no cell arrays",
                 header.supports.at(0).cell_types.empty());
  check::is_true("a header read reads no array values",
                 header.supports.at(0).node_arrays.at(0).data.f64.empty());
  check::equal("a header read still states the shape",
               header.supports.at(0).node_arrays.at(0).data.shape.size(),
               std::size_t(3));

  // Lazy access: one slot, one row, nothing else read.
  const mestra::Array one = mestra::read_slot_rows(
      path, "/supports/s0/node_arrays/pressure", 1, 2);
  check::equal("a lazy read returns one row", one.shape.at(0),
               std::size_t(1));
  check::equal("a lazy read returns the right value", one.f64.at(3), 204.0);

  // A dataset whose values do not fill the shape it declares is
  // refused rather than handed to HDF5, which would read past the end
  // of the vector.
  mestra::Dataset short_one = d;
  short_one.scalar("cl")->values.pop_back();
  bool refused = false;
  try {
    mestra::write(short_one, path);
  } catch (const mestra::Error&) {
    refused = true;
  }
  check::is_true("a short data vector is refused", refused);

  std::remove(path.c_str());
}

// The value types and the hash, at the edges a corpus file never
// reaches.
void hardened_value_types() {
  // A moved-from Value is a null, not a dictionary whose dictionary
  // has been taken.
  mestra::Dict inner;
  inner.set("x", mestra::Value::integer(1));
  mestra::Value from = mestra::Value::dict(inner);
  const mestra::Value to = std::move(from);
  check::is_true("a moved-from Value is null",
                 from.kind() == mestra::Value::Kind::Null);
  check::is_true("a moved-from Value says it is null", from.is_null());
  check::is_true("the moved-to Value has the dictionary",
                 to.as_dict().has("x"));

  // Floats compare as bits everywhere, so NaN equals NaN and -0.0 is
  // not 0.0 (section 30).
  const double nan = std::numeric_limits<double>::quiet_NaN();
  check::is_true("AttrValue NaN equals NaN",
                 mestra::AttrValue::real(nan) ==
                     mestra::AttrValue::real(nan));
  check::is_true("AttrValue -0.0 is not 0.0",
                 !(mestra::AttrValue::real(-0.0) ==
                   mestra::AttrValue::real(0.0)));
  check::is_true("Value NaN equals NaN",
                 mestra::Value::real(nan) == mestra::Value::real(nan));

  // A dictionary cannot be nested deeper than any walk of it will go,
  // so no copy or destructor can recurse past the limit either.
  mestra::Dict deep;
  bool refused = false;
  try {
    for (int i = 0; i < mestra::kMaxDictDepth + 4; ++i) {
      mestra::Dict next;
      next.set("g", mestra::Value::dict(deep));
      deep = next;
    }
  } catch (const mestra::Error& e) {
    refused = e.rule() == "E32";
  }
  check::is_true("a dictionary deeper than the limit is refused", refused);
  check::is_true("the depth stops at the limit",
                 deep.depth() <= mestra::kMaxDictDepth);

  // The digest is idempotent and the state is final once taken.
  mestra::Sha256 h;
  h.update("abc", 3);
  const std::string first = h.hex();
  const std::string again = h.hex();
  check::equal("a second hex() is the same digest", again, first);
  bool closed = false;
  try {
    h.update("d", 1);
  } catch (const mestra::Error&) {
    closed = true;
  }
  check::is_true("update after hex() is refused", closed);
}

void bytes_order() {
  // Names are ordered by their UTF-8 bytes, not by signed char.
  check::is_true("\"a\" before \"b\"", mestra::bytes_less("a", "b"));
  check::is_true("ASCII before non-ASCII",
                 mestra::bytes_less("z", "\xc3\xa9"));
  check::is_true("a prefix comes first", mestra::bytes_less("ab", "abc"));
}

}  // namespace

int main() {
  sha256_vectors();
  support_id_vectors();
  units_parser();
  codec_values();
  affine_worked_example();
  build_from_vectors();
  hardened_value_types();
  bytes_order();
  return check::finish("mestra unit tests");
}
