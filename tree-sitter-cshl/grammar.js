
const IDENTIFIER = /[a-zA-Z_@][a-zA-Z_0-9]*[?#!$]?/;
const SYMBOL = /['`\\?#!$]|\.\./;
const NUMBER = /0b[01]+|0x[0-9a-f]+|[0-9]+/;

const LEVELS = [
  ['logical', ['and', 'or', 'xor']],
  ['comparison', ['==', '!=', '<', '>', '<=', '>=', '<=>'], 'none'],
  ['bitwise', ['band', 'bor', 'bxor']],
  ['shift', ['shl', 'shr']],
  ['additive', ['+', '-']],
  ['multiplicative', ['*', '/', '%']],
  ['conversion', ['as']],
];

const choiceOf = operators => operators.length === 1 ? operators[0] : choice(...operators);
// A trailing comma is allowed everywhere.
const args = $ => seq(
  field('argument', $._expression),
  repeat(seq(',', field('argument', $._expression))),
  optional(','),
);
const items = $ => seq($._expression, repeat(seq(',', $._expression)), optional(','));
// Statements end with `;`; the last one may leave it out.
const statements = $ => choice(
  seq(repeat1(seq($._expression, ';')), optional($._expression)),
  $._expression,
);

module.exports = grammar({
  name: 'cshl',

  extras: $ => [/\s/, $.comment],

  rules: {
    program: $ => optional(statements($)),

    _expression: $ => $._backward,

    _backward: $ => choice($._forward, alias($._backward_call, $.call)),
    _backward_call: $ => prec(1, seq(
      field('argument', $._forward),
      field('function', '<|'),
      field('argument', $._backward),
    )),

    _forward: $ => choice($._separated, alias($._forward_call, $.call)),
    _forward_call: $ => prec(1, seq(
      field('argument', $._forward),
      field('function', '|>'),
      field('argument', $._separated),
    )),

    // Close the application chain on the left, then call it with the right.
    // a b | c d is (a(b))(c(d)); adjacent brackets supply call arguments.
    _separated: $ => choice($._application, alias($._separated_call, $.call)),
    _separated_call: $ => prec.left(2, seq(
      field('function', $._separated),
      choice(
        seq('|', field('argument', $._application)),
        seq('|(', optional(args($)), ')'),
        seq('|[', optional(args($)), ']'),
      ),
    )),

    _application: $ => choice($._assignment, $.call),
    call: $ => prec.right(1, seq(
      field('function', $._assignment),
      field('argument', $._application),
    )),

    _assignment: $ => choice($._logical, alias($._assignment_call, $.call), alias($._rest, $.list)),
    _rest: $ => seq('~', $._expression),
    _assignment_call: $ => prec(1, seq(
      field('argument', $._logical),
      field('function', '='),
      field('argument', $._assignment),
    )),

    ...Object.fromEntries(LEVELS.flatMap(([name, operators, associativity], index) => {
      const operand = $ => index + 1 < LEVELS.length ? $['_' + LEVELS[index + 1][0]] : $._tight;
      const left = $ => associativity === 'none' ? operand($) : $['_' + name];
      return [
        ['_' + name, $ => choice(operand($), alias($['_' + name + '_call'], $.call))],
        ['_' + name + '_call', $ => prec(1, seq(
          field('argument', left($)),
          field('function', choiceOf(operators)),
          field('argument', operand($)),
        ))],
      ];
    })),

    // Tight expressions, with no spaces between calls.
    // A bracket, brace or string calls everything before it, and `.`/`:`
    // access a member of everything before it; both are left-associative, so
    // `f(a)(b)` is `(f(a))(b)` and `x.f(a)` is `(x.f)(a)`. The items of a
    // tight (...) or [...] are the call's arguments: f(a, b) is (f a b).
    // A name, symbol or number starts a nested call (right-associative):
    // `@refT@this()` is `@refT(@this())` and `'f[x]` is `'(f[x])`.
    _tight: $ => choice($._postfix, alias($._tight_chain, $.call)),
    _postfix: $ => choice(
      $._atom,
      alias($._postfix_call, $.call),
      alias($._access, $.call),
    ),
    _postfix_call: $ => prec.left(5, seq(field('function', $._postfix), $._call_arguments)),
    _access: $ => prec.left(5, seq(
      field('argument', $._postfix),
      field('function', choice('.', ':')),
      field('argument', $._member),
    )),
    _tight_chain: $ => seq(
      field('function', $._postfix),
      field('argument', $._word_rest),
    ),

    // Chains that start with an immediate name, symbol or number.
    _word_postfix: $ => choice(
      $._adjacent_word,
      alias($._word_postfix_call, $.call),
      alias($._word_access, $.call),
    ),
    _word_postfix_call: $ => prec.left(5, seq(field('function', $._word_postfix), $._call_arguments)),
    _word_access: $ => prec.left(5, seq(
      field('argument', $._word_postfix),
      field('function', choice('.', ':')),
      field('argument', $._member),
    )),
    _word_rest: $ => choice($._word_postfix, alias($._word_chain, $.call)),
    _word_chain: $ => seq(
      field('function', $._word_postfix),
      field('argument', $._word_rest),
    ),

    _member: $ => choice($._atom, alias($._member_chain, $.call)),
    _member_chain: $ => prec(6, seq(
      field('function', $._atom),
      field('argument', $._member_rest),
    )),
    _member_rest: $ => choice($._adjacent_word, alias($._member_rest_chain, $.call)),
    _member_rest_chain: $ => prec(6, seq(
      field('function', $._adjacent_word),
      field('argument', $._member_rest),
    )),

    _call_arguments: $ => choice(
      seq(token.immediate('('), optional(args($)), ')'),
      seq(token.immediate('['), optional(args($)), ']'),
      field('argument', alias($._adjacent_block, $.block)),
      field('argument', alias($._adjacent_string, $.string)),
    ),

    _atom: $ => choice($.id, alias($._symbol, $.id), $.number, $.string, $.list, $.block),
    // Only the first token is immediate; whitespace inside brackets is allowed.
    _adjacent_word: $ => choice(
      alias(token.immediate(IDENTIFIER), $.id),
      alias(token.immediate(SYMBOL), $.id),
      alias(token.immediate(NUMBER), $.number),
    ),

    id: _ => IDENTIFIER,
    _symbol: _ => SYMBOL,
    number: _ => NUMBER,

    list: $ => choice(
      seq('(', optional(items($)), ')'),
      seq('[', optional(items($)), ']'),
    ),
    block: $ => seq('{', optional(statements($)), '}'),
    _adjacent_block: $ => seq(token.immediate('{'), optional(statements($)), '}'),

    string: $ => seq('"', $._string_body),
    _adjacent_string: $ => seq(token.immediate('"'), $._string_body),
    _string_body: $ => seq(
      repeat(choice($.string_content, $.escape_sequence)),
      token.immediate('"'),
    ),
    string_content: _ => token.immediate(/[^"\\\r\n]+/),
    escape_sequence: _ => token.immediate(choice(
      /\\["\\nrt0]/,
      /\\x\{[0-9a-f]+([ \t]+[0-9a-f]+)*\}/,
    )),

    comment: _ => token(choice(
      /\/\/[^\r\n]*/,
      /\/\*[^*]*\*+([^/*][^*]*\*+)*\//,
    )),
  },
});
