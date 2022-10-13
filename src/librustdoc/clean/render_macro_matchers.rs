use rustc_ast::token::{self, BinOpToken, Delimiter};
use rustc_ast::tokenstream::{TokenStream, TokenTree};
use rustc_ast_pretty::pprust::state::State as Printer;
use rustc_ast_pretty::pprust::PrintState;
use rustc_middle::ty::TyCtxt;
use rustc_session::parse::ParseSess;
use rustc_span::source_map::FilePathMapping;
use rustc_span::symbol::{kw, Ident, Symbol};
use rustc_span::Span;

/// Render a macro matcher in a format suitable for displaying to the user
/// as part of an item declaration.
pub(super) fn render_macro_matcher(tcx: TyCtxt<'_>, matcher: &TokenTree) -> String {
    if let Some(snippet) = snippet_equal_to_token(tcx, matcher) {
        // If the original source code is known, we display the matcher exactly
        // as present in the source code.
        return snippet;
    }

    // If the matcher is macro-generated or some other reason the source code
    // snippet is not available, we attempt to nicely render the token tree.
    let mut printer = Printer::new();

    // If the inner ibox fits on one line, we get:
    //
    //     macro_rules! macroname {
    //         (the matcher) => {...};
    //     }
    //
    // If the inner ibox gets wrapped, the cbox will break and get indented:
    //
    //     macro_rules! macroname {
    //         (
    //             the matcher ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    //             ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~!
    //         ) => {...};
    //     }
    printer.cbox(8);
    printer.word("(");
    printer.zerobreak();
    printer.ibox(0);
    match matcher {
        TokenTree::Delimited(_span, _delim, tts) => print_tts(&mut printer, tts),
        // Matcher which is not a Delimited is unexpected and should've failed
        // to compile, but we render whatever it is wrapped in parens.
        TokenTree::Token(..) => print_tt(&mut printer, matcher),
    }
    printer.end();
    printer.break_offset_if_not_bol(0, -4);
    printer.word(")");
    printer.end();
    printer.s.eof()
}

/// Find the source snippet for this token's Span, reparse it, and return the
/// snippet if the reparsed TokenTree matches the argument TokenTree.
fn snippet_equal_to_token(tcx: TyCtxt<'_>, matcher: &TokenTree) -> Option<String> {
    // Find what rustc thinks is the source snippet.
    // This may not actually be anything meaningful if this matcher was itself
    // generated by a macro.
    let source_map = tcx.sess.source_map();
    let span = matcher.span();
    let snippet = source_map.span_to_snippet(span).ok()?;

    // Create a Parser.
    let sess = ParseSess::new(rustc_driver::DEFAULT_LOCALE_RESOURCES, FilePathMapping::empty());
    let file_name = source_map.span_to_filename(span);
    let mut parser =
        match rustc_parse::maybe_new_parser_from_source_str(&sess, file_name, snippet.clone()) {
            Ok(parser) => parser,
            Err(diagnostics) => {
                drop(diagnostics);
                return None;
            }
        };

    // Reparse a single token tree.
    let mut reparsed_trees = match parser.parse_all_token_trees() {
        Ok(reparsed_trees) => reparsed_trees,
        Err(diagnostic) => {
            diagnostic.cancel();
            return None;
        }
    };
    if reparsed_trees.len() != 1 {
        return None;
    }
    let reparsed_tree = reparsed_trees.pop().unwrap();

    // Compare against the original tree.
    if reparsed_tree.eq_unspanned(matcher) { Some(snippet) } else { None }
}

fn print_tt(printer: &mut Printer<'_>, tt: &TokenTree) {
    match tt {
        TokenTree::Token(token, _) => {
            let token_str = printer.token_to_string(token);
            printer.word(token_str);
            if let token::DocComment(..) = token.kind {
                printer.hardbreak()
            }
        }
        TokenTree::Delimited(_span, delim, tts) => {
            let open_delim = printer.token_kind_to_string(&token::OpenDelim(*delim));
            printer.word(open_delim);
            if !tts.is_empty() {
                if *delim == Delimiter::Brace {
                    printer.space();
                }
                print_tts(printer, tts);
                if *delim == Delimiter::Brace {
                    printer.space();
                }
            }
            let close_delim = printer.token_kind_to_string(&token::CloseDelim(*delim));
            printer.word(close_delim);
        }
    }
}

fn print_tts(printer: &mut Printer<'_>, tts: &TokenStream) {
    #[derive(Copy, Clone, PartialEq)]
    enum State {
        Start,
        Dollar,
        DollarIdent,
        DollarIdentColon,
        DollarParen,
        DollarParenSep,
        Pound,
        PoundBang,
        Ident,
        Other,
    }

    use State::*;

    let mut state = Start;
    for tt in tts.trees() {
        let (needs_space, next_state) = match &tt {
            TokenTree::Token(tt, _) => match (state, &tt.kind) {
                (Dollar, token::Ident(..)) => (false, DollarIdent),
                (DollarIdent, token::Colon) => (false, DollarIdentColon),
                (DollarIdentColon, token::Ident(..)) => (false, Other),
                (
                    DollarParen,
                    token::BinOp(BinOpToken::Plus | BinOpToken::Star) | token::Question,
                ) => (false, Other),
                (DollarParen, _) => (false, DollarParenSep),
                (DollarParenSep, token::BinOp(BinOpToken::Plus | BinOpToken::Star)) => {
                    (false, Other)
                }
                (Pound, token::Not) => (false, PoundBang),
                (_, token::Ident(symbol, /* is_raw */ false))
                    if !usually_needs_space_between_keyword_and_open_delim(*symbol, tt.span) =>
                {
                    (true, Ident)
                }
                (_, token::Comma | token::Semi) => (false, Other),
                (_, token::Dollar) => (true, Dollar),
                (_, token::Pound) => (true, Pound),
                (_, _) => (true, Other),
            },
            TokenTree::Delimited(_, delim, _) => match (state, delim) {
                (Dollar, Delimiter::Parenthesis) => (false, DollarParen),
                (Pound | PoundBang, Delimiter::Bracket) => (false, Other),
                (Ident, Delimiter::Parenthesis | Delimiter::Bracket) => (false, Other),
                (_, _) => (true, Other),
            },
        };
        if state != Start && needs_space {
            printer.space();
        }
        print_tt(printer, tt);
        state = next_state;
    }
}

fn usually_needs_space_between_keyword_and_open_delim(symbol: Symbol, span: Span) -> bool {
    let ident = Ident { name: symbol, span };
    let is_keyword = ident.is_used_keyword() || ident.is_unused_keyword();
    if !is_keyword {
        // An identifier that is not a keyword usually does not need a space
        // before an open delim. For example: `f(0)` or `f[0]`.
        return false;
    }

    match symbol {
        // No space after keywords that are syntactically an expression. For
        // example: a tuple struct created with `let _ = Self(0, 0)`, or if
        // someone has `impl Index<MyStruct> for bool` then `true[MyStruct]`.
        kw::False | kw::SelfLower | kw::SelfUpper | kw::True => false,

        // No space, as in `let _: fn();`
        kw::Fn => false,

        // No space, as in `pub(crate) type T;`
        kw::Pub => false,

        // No space for keywords that can end an expression, as in `fut.await()`
        // where fut's Output type is `fn()`.
        kw::Await => false,

        // Otherwise space after keyword. Some examples:
        //
        // `expr as [T; 2]`
        //         ^
        // `box (tuple,)`
        //     ^
        // `break (tuple,)`
        //       ^
        // `type T = dyn (Fn() -> dyn Trait) + Send;`
        //              ^
        // `for (tuple,) in iter {}`
        //     ^
        // `if (tuple,) == v {}`
        //    ^
        // `impl [T] {}`
        //      ^
        // `for x in [..] {}`
        //          ^
        // `let () = unit;`
        //     ^
        // `match [x, y] {...}`
        //       ^
        // `&mut (x as T)`
        //      ^
        // `return [];`
        //        ^
        // `fn f<T>() where (): Into<T>`
        //                 ^
        // `while (a + b).what() {}`
        //       ^
        // `yield [];`
        //       ^
        _ => true,
    }
}
