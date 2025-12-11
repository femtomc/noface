# Idiomatic Elixir Style Guide (2025 / Elixir 1.19+)

This guide is compiled from authoritative community sources for agents working in this codebase.

## Authoritative Sources

- [Christopher Adams' Community Style Guide](https://github.com/christopheradams/elixir_style_guide)
- [Aleksei Magusev's Style Guide](https://github.com/lexmag/elixir-style-guide) - Closest to Elixir core team conventions
- [Credo Style Guide](https://github.com/rrrene/elixir-style-guide) - Basis for Credo static analysis
- [Elixir v1.19 Changelog](https://hexdocs.pm/elixir/changelog.html)

---

## Formatting

**Always run `mix format` before committing.** Configure via `.formatter.exs`.

- 2 spaces indentation, no tabs
- Lines ≤ 98 characters (configurable)
- Unix line endings (`\n`)
- Files end with a newline
- Spaces around binary operators and after commas
- No spaces inside brackets, parentheses, or braces
- No trailing whitespace

---

## Naming Conventions

| Type | Convention | Examples |
|------|------------|----------|
| Modules | `CamelCase` (preserve acronyms) | `HTTPClient`, `XMLParser`, `MyApp.User` |
| Functions | `snake_case` | `get_user`, `parse_input` |
| Variables | `snake_case` | `current_count`, `user_name` |
| Atoms | `snake_case` | `:ok`, `:error`, `:not_found` |
| Predicate functions | Trailing `?` | `valid?`, `empty?`, `authorized?` |
| Guard macros | Leading `is_` (no `?`) | `is_date/1`, `is_valid_user/1` |
| Exceptions | Trailing `Error` | `ParseError`, `ValidationError` |
| Files | `snake_case.ex` | `http_client.ex`, `user_auth.ex` |

**Avoid:**
- One-letter variable names (except in comprehensions/short lambdas)
- Names matching `Kernel` functions
- Module names matching stdlib modules

---

## Module Organization

Order module contents consistently:

```elixir
defmodule MyApp.SomeModule do
  @moduledoc """
  Brief description of the module's purpose.
  """

  # 1. Behaviours
  @behaviour GenServer

  # 2. use statements
  use GenServer

  # 3. import statements
  import SomeModule, only: [helper: 1]

  # 4. require statements
  require Logger

  # 5. alias statements (group related aliases)
  alias MyApp.{User, Account}
  alias MyApp.Repo

  # 6. Module attributes
  @default_timeout 5_000

  # 7. Struct definition
  defstruct [:id, :name, active?: true]

  # 8. Type definitions
  @type t :: %__MODULE__{
          id: integer() | nil,
          name: String.t() | nil,
          active?: boolean()
        }

  # 9. Callback implementations (for behaviours)

  # 10. Public functions

  # 11. Private functions (group with their public callers when logical)
end
```

**Tips:**
- One module per file
- Use `__MODULE__` for self-references, not hardcoded names
- Alias frequently-used modules to reveal dependencies

---

## Function Definitions

### Parentheses

```elixir
# With arguments: always use parentheses
def process(data, opts \\ []) do
  ...
end

# Without arguments: omit parentheses
def default_config do
  ...
end

# Zero-arity calls: always use parentheses (distinguishes from variables)
config = default_config()
pid = self()
env = Mix.env()
```

### Grouping

```elixir
# Group same-name functions together
def process(data) when is_list(data), do: ...
def process(data) when is_map(data), do: ...

# Separate different functions with blank lines
def process(data), do: ...

def validate(data), do: ...
```

### Single-line vs Multi-line

```elixir
# Short functions: single line OK
def valid?(%{status: :active}), do: true
def valid?(_), do: false

# Complex functions: multi-line
def process(data) do
  data
  |> validate()
  |> transform()
  |> persist()
end
```

---

## Pipelines

### Good Practices

```elixir
# Start with a bare value/variable
user
|> fetch_permissions()
|> filter_active()
|> format_response()

# Multi-line: one function per line
data
|> Step1.process()
|> Step2.transform()
|> Step3.finalize()
```

### Avoid

```elixir
# Single pipe: just call directly
data |> transform()        # Bad
transform(data)            # Good

# Starting with function call
get_data() |> process()    # Avoid
data = get_data()          # Better
data |> process()

# Anonymous functions in pipes
data |> (fn x -> x * 2 end).()  # Bad
data |> then(fn x -> x * 2 end) # OK if needed

# Pipes with side-effecting functions (unclear data flow)
```

---

## Control Flow

### Pattern Matching First

Prefer pattern matching over conditionals when possible:

```elixir
# Good: pattern match in function heads
def handle({:ok, result}), do: process(result)
def handle({:error, reason}), do: log_error(reason)

# Avoid: conditionals for type dispatch
def handle(result) do
  if match?({:ok, _}, result) do
    ...
  end
end
```

### if/unless

```elixir
# Single-line for simple cases
if valid?, do: :ok, else: :error

# Multi-line for complex cases
if valid? do
  perform_action()
  :ok
else
  :error
end

# unless: only without else
unless authorized?, do: raise "Unauthorized"

# Never use unless with else - rewrite as if
unless x, do: a, else: b   # Bad
if x, do: b, else: a       # Good

# Never use unless with negation
unless !valid?, do: ...    # Bad
if valid?, do: ...         # Good
```

### case/cond/with

```elixir
# case: for pattern matching
case result do
  {:ok, value} -> value
  {:error, :not_found} -> nil
  {:error, reason} -> raise reason
end

# cond: for boolean conditions, use true as catch-all
cond do
  count > 100 -> :high
  count > 10 -> :medium
  true -> :low
end

# with: for happy-path chaining
with {:ok, user} <- fetch_user(id),
     {:ok, perms} <- fetch_permissions(user),
     :ok <- authorize(perms, action) do
  perform_action(user)
else
  {:error, :not_found} -> {:error, "User not found"}
  {:error, :unauthorized} -> {:error, "Not authorized"}
  error -> error
end
```

### Nesting

Never nest conditionals more than once. Extract to helper functions:

```elixir
# Bad: deeply nested
if a do
  if b do
    if c do
      ...
    end
  end
end

# Good: extract logic
def process(data) do
  with :ok <- check_a(data),
       :ok <- check_b(data),
       :ok <- check_c(data) do
    perform(data)
  end
end
```

---

## Documentation & Typespecs

### Module Documentation

```elixir
defmodule MyApp.Parser do
  @moduledoc """
  Parses input data into structured formats.

  ## Examples

      iex> MyApp.Parser.parse("hello")
      {:ok, %{text: "hello"}}

  """
end

# For internal/private modules
defmodule MyApp.Internal.Helper do
  @moduledoc false
  ...
end
```

### Function Documentation

```elixir
@doc """
Fetches a user by ID.

Returns `{:ok, user}` if found, `{:error, :not_found}` otherwise.

## Examples

    iex> fetch_user(123)
    {:ok, %User{id: 123}}

    iex> fetch_user(-1)
    {:error, :not_found}

"""
@spec fetch_user(integer()) :: {:ok, User.t()} | {:error, :not_found}
def fetch_user(id) when is_integer(id) do
  ...
end
```

### Typespecs

```elixir
# Place @spec immediately before def (no blank line)
@spec process(input :: String.t(), opts :: keyword()) :: {:ok, result()} | {:error, term()}
def process(input, opts \\ []) do
  ...
end

# Name the main struct type `t`
@type t :: %__MODULE__{...}

# Break long union types across lines
@type result ::
        {:ok, success_value()}
        | {:error, :not_found}
        | {:error, :unauthorized}
        | {:error, {:validation, [String.t()]}}
```

---

## Structs

```elixir
# Atoms (defaulting to nil) first, then keyword defaults
defstruct [:id, :name, :email, active?: true, role: :user]

# Multi-line for many fields
defstruct [
  :id,
  :name,
  :email,
  active?: true,
  role: :user,
  metadata: %{}
]

# Elixir 1.19: No regex in struct defaults
# Bad:
defstruct regex: ~r/foo/

# Good:
defstruct [:regex]

def new(pattern \\ ~r/foo/) do
  %__MODULE__{regex: pattern}
end
```

---

## Collections

### Keyword Lists

```elixir
# Use special syntax
[name: "Alice", age: 30]

# Not verbose syntax
[{:name, "Alice"}, {:age, 30}]
```

### Maps

```elixir
# Atom keys: shorthand
%{name: "Alice", age: 30}

# Mixed/non-atom keys: arrow syntax
%{"name" => "Alice", :count => 5}

# Updating maps
%{user | name: "Bob"}  # Only for existing keys
Map.put(user, :new_key, value)  # For new keys
```

---

## Strings

```elixir
# Prefer <> for pattern matching
"hello" <> rest = "hello world"

# Interpolation over concatenation
"Hello, #{name}!"   # Good
"Hello, " <> name   # OK for simple cases

# Heredocs for multi-line
@doc """
This is a
multi-line string.
"""
```

---

## Error Handling

### Let It Crash

Embrace the "let it crash" philosophy with supervision trees:

```elixir
# Don't over-defensively handle every error
# Let supervisors restart failed processes
```

### Error Tuples

```elixir
# Consistent return patterns
{:ok, result}
{:error, reason}

# Error messages: lowercase, no trailing punctuation
{:error, "user not found"}
{:error, :not_found}

# Exception for Mix: capitalize error messages
```

### Raising vs Returning Errors

```elixir
# Return errors for expected failure cases
def fetch(id) do
  case Repo.get(User, id) do
    nil -> {:error, :not_found}
    user -> {:ok, user}
  end
end

# Raise for unexpected/programmer errors
def fetch!(id) do
  Repo.get!(User, id)
end
```

---

## Boolean Operators

```elixir
# and/or/not: strict boolean (both sides must be boolean)
true and false
valid? or authorized?

# &&/||/!: truthy/falsy (short-circuit evaluation)
user && user.name
config[:timeout] || 5000
```

---

## Testing (ExUnit)

```elixir
# Expression on left, expected on right
assert result == expected
assert length(list) == 3
refute is_nil(value)

# Pattern matching: pattern on left
assert {:ok, %User{id: id}} = create_user(attrs)
assert_receive {:message, _payload}

# Avoid assert true/false directly
assert valid?(data)        # Good
assert valid?(data) == true  # Redundant
```

---

## Common Pitfalls

### Never Commit

- `IEx.pry` calls
- `IO.inspect` (use `Logger` with `inspect/1` instead)
- Commented-out code
- Debug conditionals like `if true do`

### Avoid

```elixir
# Map.get/Keyword.get when pattern matching works
value = Map.get(map, :key)           # Avoid
%{key: value} = map                   # Prefer

# Unnecessary variable assignments
result = do_something()
result                                # Avoid
do_something()                        # Prefer (if returning directly)
```

### Prefer

```elixir
# Logger over IO
Logger.info("Processing #{inspect(data)}")

# Access syntax for optional nested access
get_in(data, [:user, :profile, :name])

# Enum functions over manual recursion for common operations
```

---

## Elixir 1.19 Specific

### Lazy Module Loading

Modules load lazily now. If spawning processes during compilation that reference other modules:

```elixir
# Ensure module is compiled first
Code.ensure_compiled!(MyApp.SomeModule)
Task.async(fn -> MyApp.SomeModule.work() end)

# Or use parallel compiler
Kernel.ParallelCompiler.pmap(modules, fn mod -> ... end)
```

### Type Inference

Elixir 1.19 has improved type inference. You'll get warnings for:

- Passing wrong types to protocol operations
- Type mismatches in anonymous functions
- Incompatible values in comprehensions

### Struct Updates

Pattern match before updating for better type safety:

```elixir
%URI{} = uri
%URI{uri | path: "/new"}
```

---

## Tools

- `mix format` - Automatic formatting
- `mix credo` - Static analysis (add `{:credo, "~> 1.7", only: [:dev, :test]}`)
- `mix dialyzer` - Type checking (add `{:dialyxir, "~> 1.4", only: [:dev, :test]}`)

---

*Last updated: December 2025*
