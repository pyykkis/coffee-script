# CoffeeScript can be used both on the server, as a command-line compiler based
# on Node.js/V8, or to run CoffeeScripts directly in the browser. This module
# contains the main entry functions for tokenizing, parsing, and compiling
# source CoffeeScript into JavaScript.
#
# If included on a webpage, it will automatically sniff out, compile, and
# execute all scripts present in `text/coffeescript` tags.

fs        = require 'fs'
path      = require 'path'
{Lexer}   = require './lexer'
{parser}  = require './parser'
helpers   = require './helpers'
vm        = require 'vm'
sourcemap = require './sourcemap'

# Load and run a CoffeeScript file for Node, stripping any `BOM`s.
loadFile = (module, filename) ->
  raw = fs.readFileSync filename, 'utf8'
  stripped = if raw.charCodeAt(0) is 0xFEFF then raw.substring 1 else raw
  module._compile compile(stripped, {filename, literate: helpers.isLiterate filename}), filename

if require.extensions
  for ext in ['.coffee', '.litcoffee', '.md', '.coffee.md']
    require.extensions[ext] = loadFile

# The current CoffeeScript version number.
exports.VERSION = '1.6.1'

# Expose helpers for testing.
exports.helpers = helpers

# Compile CoffeeScript code to JavaScript, using the Coffee/Jison compiler.
#
# If `options.sourceMap` is specified, then `options.filename` must also be specified.  All
# options that can be passed to `generateV3SourceMap()` may also be passed here.
#
# This returns a javascript string, unless `options.sourceMap` is passed,
# in which case this returns a `{js, v3SourceMap, sourceMap}
# object, where sourceMap is a sourcemap.coffee#SourceMap object, handy for doing programatic
# lookups.
exports.compile = compile = (code, options = {}) ->
  {merge} = exports.helpers

  if options.sourceMap
    sourceMap = new sourcemap.SourceMap()

  fragments = (parser.parse lexer.tokenize(code, options)).compileToFragments options

  currentLine = 0
  currentLine += 1 if options.header
  currentColumn = 0
  js = ""
  for fragment in fragments
    # Update the sourcemap with data from each fragment
    if sourceMap
      if fragment.locationData
        sourceMap.addMapping(
          [fragment.locationData.first_line, fragment.locationData.first_column],
          [currentLine, currentColumn],
          {noReplace: true})
      newLines = helpers.count fragment.code, "\n"
      currentLine += newLines
      currentColumn = fragment.code.length - (if newLines then fragment.code.lastIndexOf "\n" else 0)

    # Copy the code from each fragment into the final JavaScript.
    js += fragment.code

  if options.header
    header = "Generated by CoffeeScript #{@VERSION}"
    js = "// #{header}\n#{js}"

  if options.sourceMap
    answer = {js}
    if sourceMap
      answer.sourceMap = sourceMap
      answer.v3SourceMap = sourcemap.generateV3SourceMap(sourceMap, options)
    answer
  else
    js

# Tokenize a string of CoffeeScript code, and return the array of tokens.
exports.tokens = (code, options) ->
  lexer.tokenize code, options

# Parse a string of CoffeeScript code or an array of lexed tokens, and
# return the AST. You can then compile it by calling `.compile()` on the root,
# or traverse it by using `.traverseChildren()` with a callback.
exports.nodes = (source, options) ->
  if typeof source is 'string'
    parser.parse lexer.tokenize source, options
  else
    parser.parse source

# Compile and execute a string of CoffeeScript (on the server), correctly
# setting `__filename`, `__dirname`, and relative `require()`.
exports.run = (code, options = {}) ->
  mainModule = require.main

  # Set the filename.
  mainModule.filename = process.argv[1] =
      if options.filename then fs.realpathSync(options.filename) else '.'

  # Clear the module cache.
  mainModule.moduleCache and= {}

  # Assign paths for node_modules loading
  mainModule.paths = require('module')._nodeModulePaths path.dirname fs.realpathSync options.filename

  # Compile.
  if not helpers.isCoffee(mainModule.filename) or require.extensions
    mainModule._compile compile(code, options), mainModule.filename
  else
    mainModule._compile code, mainModule.filename

# Compile and evaluate a string of CoffeeScript (in a Node.js-like environment).
# The CoffeeScript REPL uses this to run the input.
exports.eval = (code, options = {}) ->
  return unless code = code.trim()
  Script = vm.Script
  if Script
    if options.sandbox?
      if options.sandbox instanceof Script.createContext().constructor
        sandbox = options.sandbox
      else
        sandbox = Script.createContext()
        sandbox[k] = v for own k, v of options.sandbox
      sandbox.global = sandbox.root = sandbox.GLOBAL = sandbox
    else
      sandbox = global
    sandbox.__filename = options.filename || 'eval'
    sandbox.__dirname  = path.dirname sandbox.__filename
    # define module/require only if they chose not to specify their own
    unless sandbox isnt global or sandbox.module or sandbox.require
      Module = require 'module'
      sandbox.module  = _module  = new Module(options.modulename || 'eval')
      sandbox.require = _require = (path) ->  Module._load path, _module, true
      _module.filename = sandbox.__filename
      _require[r] = require[r] for r in Object.getOwnPropertyNames require when r isnt 'paths'
      # use the same hack node currently uses for their own REPL
      _require.paths = _module.paths = Module._nodeModulePaths process.cwd()
      _require.resolve = (request) -> Module._resolveFilename request, _module
  o = {}
  o[k] = v for own k, v of options
  o.bare = on # ensure return value
  js = compile code, o
  if sandbox is global
    vm.runInThisContext js
  else
    vm.runInContext js, sandbox

# Instantiate a Lexer for our use here.
lexer = new Lexer

# The real Lexer produces a generic stream of tokens. This object provides a
# thin wrapper around it, compatible with the Jison API. We can then pass it
# directly as a "Jison lexer".
parser.lexer =
  lex: ->
    token = @tokens[@pos++]
    if token
      [tag, @yytext, @yylloc] = token
      @yylineno = @yylloc.first_line
    else
      tag = ''

    tag
  setInput: (@tokens) ->
    @pos = 0
  upcomingInput: ->
    ""

# Make all the AST nodes visible to the parser.
parser.yy = require './nodes'

# Override Jison's default error handling function.
parser.yy.parseError = (message, {token}) ->
  # Disregard Jison's message, it contains redundant line numer information.
  message = "unexpected #{if token is 1 then 'end of input' else token}"
  # The second argument has a `loc` property, which should have the location
  # data for this token. Unfortunately, Jison seems to send an outdated `loc`
  # (from the previous token), so we take the location information directly
  # from the lexer.
  helpers.throwSyntaxError message, parser.lexer.yylloc