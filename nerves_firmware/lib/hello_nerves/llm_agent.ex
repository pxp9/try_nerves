defmodule HelloNerves.LLMAgent do
  @moduledoc """
  An LLM Agent that uses ReqLLM with Anthropic Claude to interact with hardware tools.

  Tools (LCD, LED, LightSensor) register themselves with this agent
  when they are ready by providing ReqLLM.Tool definitions.
  """

  use GenServer
  require Logger

  alias ReqLLM.{Context, Tool}

  @default_model "google:gemini-flash-lite-latest"

  defstruct tools: %MapSet{},
            model: nil,
            history: nil

  ## Public API

  @doc """
  Start the LLM Agent GenServer.

  Options:
    - :model - The model to use (default: "#{@default_model}")

  Note: API key is managed by ReqLLM via Application.get_env(:req_llm, :google_api_key)
  """
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Register a tool with the agent.

  ## Parameters
    - name: Tool name (e.g., "lcd_display")
    - description: What the tool does
    - parameter_schema: NimbleOptions-style parameters schema
    - callback: Function or {Module, :function} tuple

  ## Example
      HelloNerves.LLMAgent.register_tool(
        "lcd_display",
        "Display text on the LCD screen",
        [
          text: [type: :string, required: true, doc: "Text to display on the LCD"]
        ],
        {HelloNerves.Tools.LCD, :display}
      )
  """
  def register_tool(name, description, parameter_schema, callback) do
    GenServer.call(__MODULE__, {:register_tool, name, description, parameter_schema, callback})
  end

  @doc """
  Send a prompt to the LLM agent and get a response.
  The agent will automatically use registered tools when appropriate.

  Returns {:ok, response} or {:error, reason}
  """
  def prompt(message) when is_binary(message) do
    GenServer.call(__MODULE__, {:prompt, message}, 30_000)
  end

  @doc """
  List all registered tools.
  """
  def list_tools do
    GenServer.call(__MODULE__, :list_tools)
  end

  @doc """
  Reset the conversation history (keeps tools registered).
  """
  def reset_history do
    GenServer.call(__MODULE__, :reset_history)
  end

  ## GenServer Callbacks

  @impl true
  def init(opts) do
    model = Keyword.get(opts, :model, @default_model)

    system_prompt =
      Keyword.get(opts, :system_prompt, """
      You are a helpful AI assistant controlling embedded hardware.

      When the user asks you to perform hardware actions, use the appropriate tools.

      Always use tools when appropriate and provide clear, helpful responses about what you did.

      Be concise and friendly in your responses.
      """)

    history = Context.new([Context.system(system_prompt)])

    state = %__MODULE__{
      tools: MapSet.new(),
      model: model,
      history: history
    }

    Logger.info("LLM Agent started with model: #{model}")

    {:ok, state}
  end

  @impl true
  def handle_call({:register_tool, name, description, parameter_schema, callback}, _from, state) do
    tool =
      ReqLLM.tool(
        name: name,
        description: description,
        parameter_schema: parameter_schema,
        callback: callback
      )

      new_tools = MapSet.put(state.tools, tool)
      Logger.info("Registered tool: #{name}")
      {:reply, :ok, %{state | tools: new_tools}}
  end

  @impl true
  def handle_call(:list_tools, _from, state) do
    tool_list =
      state.tools
      |> Enum.map(fn tool ->
        %{name: tool.name, description: tool.description}
      end)

    {:reply, tool_list, state}
  end

  @impl true
  def handle_call({:prompt, message}, _from, state) do
    # Add user message to history
    new_history = Context.append(state.history, Context.user(message))

    case stream_and_handle_tools(state.model, new_history, state.tools) do
      {:ok, final_history, final_response} ->
        # Update state with new history
        {:reply, {:ok, final_response}, %{state | history: final_history}}

      {:error, error} ->
        Logger.error("LLM request failed: #{inspect(error)}")
        {:reply, {:error, error}, state}
    end
  end

  @impl true
  def handle_call(:reset_history, _from, state) do
    # Extract system prompt from current history
    system_messages =
      state.history.messages
      |> Enum.filter(fn msg -> msg.role == :system end)

    new_history = Context.new(system_messages)
    Logger.info("LLM Agent: Conversation history reset")

    {:reply, :ok, %{state | history: new_history}}
  end

  # Handle streaming completion messages
  @impl true
  def handle_info({:stream_task_completed, _context}, state) do
    {:noreply, state}
  end

  @impl true
  def handle_info({ref, :ok}, state) when is_reference(ref) do
    {:noreply, state}
  end

  @impl true
  def handle_info({ref, _result}, state) when is_reference(ref) do
    {:noreply, state}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, _pid, _reason}, state) do
    {:noreply, state}
  end

  @impl true
  def handle_info(_msg, state) do
    {:noreply, state}
  end

  ## Private Functions

  defp stream_and_handle_tools(model, history, tools) do
    # Convert MapSet to list for ReqLLM
    tools_list = MapSet.to_list(tools)

    case ReqLLM.stream_text(model, history.messages, tools: tools_list) do
      {:ok, stream_response} ->
        # Collect all chunks
        chunks = Enum.to_list(stream_response.stream)

        case extract_tool_calls_from_chunks(chunks) do
          [] ->
            # No tool calls, just return the text
            text = chunks |> Enum.map_join("", & &1.text)
            final_history = Context.append(history, Context.assistant(text))
            {:ok, final_history, text}

          tool_calls ->
            # Tool calls found
            initial_text = chunks |> Enum.map_join("", & &1.text)

            assistant_message = Context.assistant(initial_text, tool_calls: tool_calls)
            history_with_tool_call = Context.append(history, assistant_message)

            Logger.info("Executing #{length(tool_calls)} tool call(s)")

            # Execute tools and collect results
            history_with_results =
              Enum.reduce(tool_calls, history_with_tool_call, fn tool_call, ctx ->
                # Find the tool
                tool = Enum.find(tools, fn t -> t.name == tool_call.name end)

                ## it will crash if we have nil but it is fine.
                %ReqLLM.Tool{} = tool

                case Tool.execute(tool, tool_call.arguments) do
                  {:ok, result} ->
                    Logger.info(
                      "Tool #{tool_call.name}(#{inspect(tool_call.arguments)}) → #{inspect(result)}"
                    )

                    tool_result_msg =
                      Context.tool_result_message(tool_call.name, tool_call.id, result)

                    Context.append(ctx, tool_result_msg)

                  {:error, error} ->
                    Logger.error("Tool #{tool_call.name} failed: #{inspect(error)}")
                    error_result = %{error: "Tool execution failed: #{inspect(error)}"}

                    tool_result_msg =
                      Context.tool_result_message(tool_call.name, tool_call.id, error_result)

                    Context.append(ctx, tool_result_msg)
                end
              end)

            # Get final response from LLM after tool execution
            case ReqLLM.stream_text(model, history_with_results.messages) do
              {:ok, final_stream_response} ->
                final_chunks = Enum.to_list(final_stream_response.stream)
                final_text = final_chunks |> Enum.map_join("", & &1.text)

                final_history =
                  Context.append(history_with_results, Context.assistant(final_text))

                {:ok, final_history, final_text}

              {:error, error} ->
                {:error, error}
            end
        end

      {:error, error} ->
        {:error, error}
    end
  end

  defp extract_tool_calls_from_chunks(chunks) do
    # Base tool calls with index
    tool_calls =
      chunks
      |> Enum.filter(&(&1.type == :tool_call))
      |> Enum.map(fn chunk ->
        Logger.debug("Tool call chunk: #{inspect(chunk)}")
        %{
          id: Map.get(chunk.metadata, :id) || "call_#{:erlang.unique_integer()}",
          name: chunk.name,
          arguments: chunk.arguments || %{},
          index: Map.get(chunk.metadata, :index, 0)
        }
      end)

    Logger.debug("Extracted base tool calls: #{inspect(tool_calls)}")

    # Collect argument fragments from meta chunks
    meta_chunks = chunks |> Enum.filter(&(&1.type == :meta))
    Logger.debug("Meta chunks count: #{length(meta_chunks)}")
    Logger.debug("Meta chunks sample: #{inspect(Enum.take(meta_chunks, 3))}")
    arg_fragments =
      chunks
      |> Enum.filter(fn
        %{type: :meta, metadata: %{tool_call_args: _}} -> true
        _ -> false
      end)
      |> Enum.group_by(& &1.metadata.tool_call_args.index)
      |> Map.new(fn {index, fragments} ->
        json = fragments |> Enum.map_join("", & &1.metadata.tool_call_args.fragment)
        {index, json}
      end)

    Logger.debug("Collected arg_fragments: #{inspect(arg_fragments)}")

    # Merge accumulated JSON back into tool calls
    final_calls = tool_calls
    |> Enum.map(fn call ->
      case Map.get(arg_fragments, call.index) do
        nil ->
          Logger.debug("No arg fragments for call #{call.name} at index #{call.index}")
          Map.delete(call, :index)

        json ->
          Logger.debug("Decoding JSON for call #{call.name}: #{json}")
          case Jason.decode(json) do
            {:ok, args} ->
              Logger.debug("Decoded args: #{inspect(args)}")
              call |> Map.put(:arguments, args) |> Map.delete(:index)
            # keep empty args if invalid JSON
            {:error, _} -> Map.delete(call, :index)
          end
      end
    end)

    Logger.debug("Final tool calls with arguments: #{inspect(final_calls)}")
    final_calls
  end
end
