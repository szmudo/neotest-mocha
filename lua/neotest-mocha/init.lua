local async = require "neotest.async"
local lib = require "neotest.lib"
local logger = require "neotest.logging"
local util = require "neotest-mocha.util"

---@class neotest.MochaSpecContext
---@field results_path string
---@field test_name_pattern string
---@field path string

---@class neotest.MochaOptions
---@field command? string|fun(path:string): string
---@field command_args? fun(context:neotest.MochaSpecContext): string[]
---@field env? table<string, string>|fun(): table<string, string>
---@field cwd? string|fun(): string
---@field is_test_file? fun(path:string): boolean
---@field filter_dir? fun(name: string, rel_path: string, root: string): boolean

---@type fun(path:string):string
local get_mocha_command = util.get_mocha_command

---@type fun(context:neotest.MochaSpecContext): string[]
local get_mocha_command_args = util.get_mocha_command_args

---@type fun(env:string[]): table<string, string>?
local get_env = util.get_env

---@type fun(path:string):string|nil
local get_cwd = util.get_cwd

---@type neotest.Adapter
local Adapter = { name = "neotest-mocha" }

---Find the project root directory given a current directory to work from.
---Should no root be found, the adapter can still be used in a non-project context if a test file matches.
---@async
---@param dir string @Directory to treat as cwd
---@return string | nil @Absolute root dir of test suite
Adapter.root = lib.files.match_root_pattern "package.json"

local default_is_test_file = util.create_test_file_extensions_matcher({ "mocha" }, { "js", "mjs", "cjs" })

local is_test_file = default_is_test_file

local status = vim
  .system({ "node", "-p", 'try { require.resolve("mocha") } catch { process.exit(1) }' }, { text = true })
  :wait()
local mochaInstalled = status.code == 0
if not mochaInstalled then
  logger.warn "Mocha not found in project"
end

---@async
---@param file_path string
---@return boolean
function Adapter.is_test_file(file_path)
  local rootPath = util.find_package_json_ancestor(file_path)

  if not rootPath then
    return false
  end

  -- This is a test file if it matches the supported extensions and a parent directory
  -- contains a package.json file with mocha installed. The latter is necessary to
  -- support monorepos where there are multiple parent directories with a package.json
  -- and the current file's position in the monorepo has to be taken into account as well
  return is_test_file(file_path) and mochaInstalled
end

local filter_dir = function(name)
  return name ~= "node_modules"
end

---Filter directories when searching for test files
---@async
---@param name string Name of directory
---@param rel_path string Path to directory, relative to root
---@param root string Root directory of project
---@return boolean
function Adapter.filter_dir(...)
  return filter_dir(...)
end

---@param s string
---@return boolean
local function isTemplateLiteral(s)
  return string.sub(s, 1, 1) == "`"
end

---@param s string
---@return string
local function getStringFromTemplateLiteral(s)
  local matched = string.match(s, "^`(.*)`$")
  if not matched then
    return s
  end
  return (
    matched
      :gsub("%${.*}", ".*") -- template literal ${var}
      :gsub("%%s", "\\w*") -- test each %s string param
      :gsub("%%i", "\\d*") -- test each %i integer param
      :gsub("%%d", ".*") -- test each %d number param
      :gsub("%%f", ".*") -- test each %f float param
      :gsub("%%j", ".*") -- test each %j json param
      :gsub("%%o", ".*") -- test each %o object param
      :gsub("%%#", "\\d*") -- test each %# index param
  )
end

---Given a file path, parse all the tests within it.
---@async
---@param file_path string Absolute file path
---@return neotest.Tree | nil
function Adapter.discover_positions(file_path)
  local query = [[
    ; -- Namespaces --
    ; Matches: `describe('context')`
    ((call_expression
      function: (identifier) @func_name (#any-of? @func_name "describe" "context")
      arguments: (arguments (string (string_fragment) @namespace.name) (_))
    )) @namespace.definition
    ; Matches: `describe.only('context')`
    ((call_expression
      function: (member_expression
        object: (identifier) @func_name (#any-of? @func_name "describe" "context")
      )
      arguments: (arguments (string (string_fragment) @namespace.name) (_))
    )) @namespace.definition

    ; -- Tests --
    ; Matches: `it('test') / specify('test')`
    ((call_expression
      function: (identifier) @func_name (#any-of? @func_name "it" "specify")
      arguments: (arguments [(template_string) @test.name (string (string_fragment) @test.name)]  [(arrow_function) (function_expression)])
    )) @test.definition
    ; Matches: `it.only('test') / specify.only('test')`
    ((call_expression
      function: (member_expression
        object: (identifier) @func_name (#any-of? @func_name "it" "specify")
      )
      arguments: (arguments [(template_string) @test.name (string (string_fragment) @test.name)]  [(arrow_function) (function_expression)])
    )) @test.definition
  ]]

  local parsedTree = lib.treesitter.parse_positions(file_path, query, { nested_tests = true })

  for _, node in parsedTree:iter_nodes() do
    if #node:children() > 0 then
      for _, pos in node:iter_nodes() do
        if pos.type == "test" then
          local test = pos:data()
          if isTemplateLiteral(test.name) then
            local testNode = parsedTree:get_key(test.id)
            local originalId = test.id
            if not testNode then
              return
            end
            local parent = testNode:parent()
            if not parent then
              return
            end

            test.name = getStringFromTemplateLiteral(test.name)
            test.id = test.path .. "::" .. test.name

            --[[ vim.pretty_print(parent) ]]
            --[[ vim.pretty_print(parent._children) ]]
            --[[ vim.pretty_print(parent._children[1]) ]]
            for i, child in pairs(parent._children) do
              if originalId == child:data().id then
                parent._children[i]:data().id = test.id
              end
            end
            testNode._parent = parent
          end
        end
      end
    end
  end

  return parsedTree
end

---@param args neotest.RunArgs
---@return neotest.RunSpec
function Adapter.build_spec(args)
  local results_path = async.fn.tempname() .. ".json"
  local tree = args.tree

  if not tree then
    return {}
  end

  local pos = tree:data()
  local testNamePattern = ".*"

  if pos.type == "test" or pos.type == "namespace" then
    local testName = string.sub(pos.id, string.find(pos.id, "::") + 2)
    testName, _ = string.gsub(testName, "::", " ")
    testNamePattern = "^" .. util.escape_test_pattern(testName)
    testNamePattern = testNamePattern .. (pos.type == "test" and "$" or "")
  end

  local binary = get_mocha_command(pos.path)
  local command = vim.split(binary, "%s+")
  local command_args = get_mocha_command_args {
    results_path = results_path,
    test_name_pattern = testNamePattern,
    path = pos.path,
  }

  if vim.tbl_islist(command_args) then
    vim.list_extend(command, command_args)
  end

  local cwd = get_cwd(pos.path)

  return {
    command = command,
    cwd = cwd,
    context = {
      results_path = results_path,
      file = pos.path,
    },
    strategy = util.get_strategy_config(args.strategy, command, cwd),
    env = get_env(args[2] and args[2].env or {}),
  }
end

---@async
---@param spec neotest.RunSpec
---@param result neotest.StrategyResult
---@param tree neotest.Tree
---@return table<string, neotest.Result>
function Adapter.results(spec, result, tree)
  local output_file = spec.context.results_path
  local success, data = pcall(lib.files.read, output_file)

  if not success then
    logger.error("No test output file found ", output_file)
    return {}
  end

  local ok, parsed = pcall(vim.json.decode, data, { luanil = { object = true } })

  if not ok then
    logger.error("Failed to parse test output json ", output_file)
    return {}
  end

  local results = util.parsed_json_to_results(parsed, tree, result.output)

  return results
end

local is_callable = function(obj)
  return type(obj) == "function" or (type(obj) == "table" and obj.__call)
end

setmetatable(Adapter, {
  ---@param opts neotest.MochaOptions
  __call = function(_, opts)
    is_test_file = opts.is_test_file or is_test_file

    if is_callable(opts.command) then
      ---@diagnostic disable-next-line: cast-local-type
      get_mocha_command = opts.command
    elseif opts.command then
      get_mocha_command = function()
        ---@diagnostic disable-next-line: return-type-mismatch
        return opts.command
      end
    end

    if is_callable(opts.command_args) then
      get_mocha_command_args = opts.command_args
    end

    if is_callable(opts.env) then
      ---@diagnostic disable-next-line: cast-local-type
      get_env = opts.env
    elseif opts.env then
      get_env = function(env)
        ---@diagnostic disable-next-line: param-type-mismatch
        return vim.tbl_extend("force", opts.env, env)
      end
    end

    if is_callable(opts.cwd) then
      ---@diagnostic disable-next-line: cast-local-type
      get_cwd = opts.cwd
    elseif opts.cwd then
      get_cwd = function()
        ---@diagnostic disable-next-line: return-type-mismatch
        return opts.cwd
      end
    end

    if is_callable(opts.filter_dir) then
      filter_dir = opts.filter_dir
    end

    return Adapter
  end,
})

return Adapter
