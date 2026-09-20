// The units parser W10 is driven by.
//
// SPEC.md section 3 asks for the UDUNITS grammar CF uses and makes an
// unparseable string a warning in version 0.  This is the grammar and
// not a units database: it decides whether a string is well formed,
// not whether "qux" is a unit anyone has heard of.  That is the
// smallest thing that tells "W m-2" and "m2 s-1" from "kg/(m s".
//
//   expr    := product
//   product := power ( ('*' | '/' | ' '+) power )*
//   power   := atom ( ('^' | '**')? sign? digits )?
//   atom    := '(' expr ')' | number | identifier
//
// An identifier is a letter followed by letters, digits, '_' or '%',
// which covers the prefixed names UDUNITS allows.  A number is a
// decimal literal, so that "1" parses as the dimensionless unit.

#include "mestra/validate.hpp"

#include <cctype>
#include <cstddef>

namespace mestra {
namespace {

class Parser {
 public:
  explicit Parser(const std::string& s) : s_(s) {}

  bool parse() {
    skip_space();
    if (!expr()) return false;
    skip_space();
    return at_ == s_.size();
  }

 private:
  char peek() const { return at_ < s_.size() ? s_[at_] : '\0'; }
  bool eof() const { return at_ >= s_.size(); }
  void skip_space() {
    while (at_ < s_.size() && (s_[at_] == ' ' || s_[at_] == '\t')) ++at_;
  }

  bool expr() { return product(); }

  bool product() {
    if (!power()) return false;
    for (;;) {
      const std::size_t save = at_;
      bool sep = false;
      while (at_ < s_.size() && (s_[at_] == ' ' || s_[at_] == '\t')) {
        ++at_;
        sep = true;
      }
      if (!eof() && (peek() == '*' || peek() == '/')) {
        // "**" is exponentiation, not two multiplications.
        if (peek() == '*' && at_ + 1 < s_.size() && s_[at_ + 1] == '*') {
          at_ = save;
          return true;
        }
        ++at_;
        skip_space();
        sep = true;
      } else if (!sep) {
        at_ = save;
        return true;
      } else if (eof() || peek() == ')') {
        at_ = save;
        return true;
      }
      if (!power()) {
        at_ = save;
        return true;
      }
    }
  }

  bool power() {
    if (!atom()) return false;
    const std::size_t save = at_;
    if (!eof() && peek() == '^') {
      ++at_;
    } else if (at_ + 1 < s_.size() && peek() == '*' && s_[at_ + 1] == '*') {
      at_ += 2;
    }
    const bool had_operator = at_ != save;
    if (!eof() && (peek() == '+' || peek() == '-')) ++at_;
    std::size_t digits = 0;
    while (!eof() && std::isdigit(static_cast<unsigned char>(peek()))) {
      ++at_;
      ++digits;
    }
    if (digits == 0) {
      if (had_operator) return false;   // "m^" is not a unit
      at_ = save;
    }
    return true;
  }

  bool atom() {
    if (eof()) return false;
    if (peek() == '(') {
      ++at_;
      skip_space();
      if (!expr()) return false;
      skip_space();
      if (eof() || peek() != ')') return false;
      ++at_;
      return true;
    }
    const char c = peek();
    if (std::isdigit(static_cast<unsigned char>(c)) || c == '.') {
      std::size_t digits = 0;
      while (!eof() && std::isdigit(static_cast<unsigned char>(peek()))) {
        ++at_;
        ++digits;
      }
      if (!eof() && peek() == '.') {
        ++at_;
        while (!eof() && std::isdigit(static_cast<unsigned char>(peek()))) {
          ++at_;
          ++digits;
        }
      }
      if (digits == 0) return false;
      // An exponent on a bare number, as in "1e-3".
      if (!eof() && (peek() == 'e' || peek() == 'E')) {
        const std::size_t save = at_;
        ++at_;
        if (!eof() && (peek() == '+' || peek() == '-')) ++at_;
        std::size_t exp_digits = 0;
        while (!eof() && std::isdigit(static_cast<unsigned char>(peek()))) {
          ++at_;
          ++exp_digits;
        }
        if (exp_digits == 0) at_ = save;
      }
      return true;
    }
    if (std::isalpha(static_cast<unsigned char>(c)) || c == '%') {
      ++at_;
      while (!eof()) {
        const char n = peek();
        if (std::isalpha(static_cast<unsigned char>(n)) || n == '_' ||
            n == '%') {
          ++at_;
        } else {
          break;
        }
      }
      return true;
    }
    return false;
  }

  const std::string& s_;
  std::size_t at_ = 0;
};

}  // namespace

bool units_parse(const std::string& units) {
  if (units.empty()) return false;
  Parser p(units);
  return p.parse();
}

}  // namespace mestra
