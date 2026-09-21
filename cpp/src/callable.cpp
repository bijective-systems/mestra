#include "mestra/callable.hpp"

#include <map>

#include "mestra/io.hpp"

namespace mestra {

std::size_t KeysTable::rows() const {
  for (const std::vector<double>& c : numeric) {
    if (!c.empty()) return c.size();
  }
  for (const std::vector<std::string>& c : text) {
    if (!c.empty()) return c.size();
  }
  // Every column is empty: the table has the length the columns agree
  // on, which is zero.
  return 0;
}

bool KeysTable::has(const std::string& name) const {
  for (const std::string& n : names) {
    if (n == name) return true;
  }
  return false;
}

const std::vector<double>& KeysTable::column(const std::string& name) const {
  for (std::size_t i = 0; i < names.size(); ++i) {
    if (names[i] == name && i < numeric.size()) return numeric[i];
  }
  // Section 26: a missing column that the callable declares is an
  // error at call time.
  throw Error("", "the keys table has no column \"" + name + "\"");
}

const std::vector<std::string>& KeysTable::text_column(
    const std::string& name) const {
  for (std::size_t i = 0; i < names.size(); ++i) {
    if (names[i] == name && i < text.size()) return text[i];
  }
  throw Error("", "the keys table has no text column \"" + name + "\"");
}

void KeysTable::add_column(const std::string& name,
                           std::vector<double> values) {
  names.push_back(name);
  numeric.resize(names.size());
  text.resize(names.size());
  numeric.back() = std::move(values);
}

void KeysTable::add_text_column(const std::string& name,
                                std::vector<std::string> values) {
  names.push_back(name);
  numeric.resize(names.size());
  text.resize(names.size());
  text.back() = std::move(values);
}

void Prediction::check(const std::string& where) const {
  const std::string at = where.empty() ? std::string() : where + ": ";
  if (!uncertainty.has_value()) {
    if (level.has_value() || method.has_value()) {
      throw Error("", at + "level and method go with an uncertainty; a "
                           "prediction without one has neither (section 10)");
    }
    return;
  }
  if (uncertainty->shape != mean.shape) {
    throw Error("", at + "a band has the shape of its mean (section 10)");
  }
  if (!level.has_value() || !(*level > 0.0 && *level < 1.0)) {
    throw Error("", at + "a band states the coverage it claims as level in "
                         "(0, 1); a 1.96-sigma Gaussian band is 0.95");
  }
  if (!method.has_value() || method->empty()) {
    throw Error("", at + "a band says how it was made; give method one "
                         "sentence");
  }
  for (const double v : uncertainty->f64) {
    if (v < 0.0) {
      throw Error("", at + "a band is a half-width and is never negative");
    }
  }
}

bool Outputs::has(const std::string& output) const {
  return by_output.find(output) != by_output.end();
}

const Prediction& Outputs::at(const std::string& output) const {
  const auto it = by_output.find(output);
  if (it == by_output.end()) {
    throw Error("", "this callable has no output \"" + output + "\"");
  }
  return it->second;
}

void Outputs::set(const std::string& output, Prediction p) {
  by_output[output] = std::move(p);
}

namespace {

std::map<std::string, CallableRegistry::Factory, BytesLess>& registry() {
  static std::map<std::string, CallableRegistry::Factory, BytesLess> r;
  return r;
}

}  // namespace

void CallableRegistry::register_type(const std::string& type,
                                     Factory factory) {
  registry()[type] = std::move(factory);
}

bool CallableRegistry::knows(const std::string& type) {
  return registry().find(type) != registry().end();
}

std::unique_ptr<Callable> CallableRegistry::from_dict(
    const std::string& type, const Dict& dict) {
  const auto it = registry().find(type);
  if (it == registry().end()) return nullptr;
  return it->second(dict);
}

std::vector<std::string> CallableRegistry::types() {
  std::vector<std::string> out;
  for (const auto& entry : registry()) out.push_back(entry.first);
  return out;
}

}  // namespace mestra
