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

      Always answer in the same language as the user.

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
    tools_list = MapSet.to_list(tools)

    with {:ok, stream_response} <- ReqLLM.stream_text(model, history.messages, tools: tools_list),
         chunks <- Enum.to_list(stream_response.stream),
         tool_calls <- extract_tool_calls_from_chunks(chunks) do
      handle_llm_response(model, history, tools, tools_list, chunks, tool_calls)
    end
  end

  defp handle_llm_response(_model, history, _tools, _tools_list, chunks, []) do
    # No tool calls, just return the text
    text = extract_text_from_chunks(chunks)
    final_history = Context.append(history, Context.assistant(text))
    {:ok, final_history, text}
  end

  defp handle_llm_response(model, history, tools, tools_list, chunks, tool_calls) do
    Logger.info("Executing #{length(tool_calls)} tool call(s)")

    history
    |> add_tool_call_to_history(chunks, tool_calls)
    |> execute_all_tools(tools_list, tool_calls)
    |> get_final_llm_response(model, tools, tools_list)
  end

  defp add_tool_call_to_history(history, chunks, tool_calls) do
    initial_text = extract_text_from_chunks(chunks)
    assistant_message = Context.assistant(initial_text, tool_calls: tool_calls)
    Context.append(history, assistant_message)
  end

  defp execute_all_tools(history, tools_list, tool_calls) do
    Enum.reduce(tool_calls, history, fn tool_call, ctx ->
      execute_single_tool(ctx, tools_list, tool_call)
    end)
  end

  defp execute_single_tool(context, tools_list, tool_call) do
    tool = Enum.find(tools_list, fn t -> t.name == tool_call.name end)
    %ReqLLM.Tool{} = tool  # Crash if tool not found

    case Tool.execute(tool, tool_call.arguments) do
      {:ok, result} ->
        log_tool_result(tool_call, {:ok, result})
        append_tool_result(context, tool_call, result)

      {:error, error} ->
        log_tool_result(tool_call, {:error, error})
        error_result = %{error: "Tool execution failed: #{inspect(error)}"}
        append_tool_result(context, tool_call, error_result)
    end
  end

  defp append_tool_result(context, tool_call, result) do
    tool_result_msg = Context.tool_result_message(tool_call.name, tool_call.id, result)
    Context.append(context, tool_result_msg)
  end

  defp get_final_llm_response(history_with_results, model, tools, tools_list) do
    case ReqLLM.stream_text(model, history_with_results.messages, tools: tools_list) do
      {:ok, final_stream_response} ->
        final_chunks = Enum.to_list(final_stream_response.stream)
        final_tool_calls = extract_tool_calls_from_chunks(final_chunks)

        handle_final_response(model, history_with_results, tools, final_chunks, final_tool_calls)

      {:error, error} ->
        {:error, error}
    end
  end

  defp handle_final_response(_model, history, _tools, final_chunks, []) do
    # No more tool calls, return the final text
    final_text = extract_text_from_chunks(final_chunks)
    final_history = Context.append(history, Context.assistant(final_text))
    {:ok, final_history, final_text}
  end

  defp handle_final_response(model, history, tools, _final_chunks, _more_tool_calls) do
    # Recursively handle more tool calls
    stream_and_handle_tools(model, history, tools)
  end

  defp extract_text_from_chunks(chunks) do
    Enum.map_join(chunks, "", & &1.text)
  end

  defp log_tool_result(tool_call, {:ok, result}) do
    Logger.info("Tool #{tool_call.name}(#{inspect(tool_call.arguments)}) → #{inspect(result)}")
  end

  defp log_tool_result(tool_call, {:error, error}) do
    Logger.error("Tool #{tool_call.name} failed: #{inspect(error)}")
  end

  defp extract_tool_calls_from_chunks(chunks) do
    tool_calls = extract_base_tool_calls(chunks)
    arg_fragments = collect_argument_fragments(chunks)

    merge_arguments_into_tool_calls(tool_calls, arg_fragments)
  end

  defp extract_base_tool_calls(chunks) do
    chunks
    |> Enum.filter(&(&1.type == :tool_call))
    |> Enum.map(&build_tool_call_from_chunk/1)
    |> tap(&Logger.debug("Extracted base tool calls: #{inspect(&1)}"))
  end

  defp build_tool_call_from_chunk(chunk) do
    Logger.debug("Tool call chunk: #{inspect(chunk)}")

    %{
      id: Map.get(chunk.metadata, :id) || "call_#{:erlang.unique_integer()}",
      name: chunk.name,
      arguments: chunk.arguments || %{},
      index: Map.get(chunk.metadata, :index, 0)
    }
  end

  defp collect_argument_fragments(chunks) do
    chunks
    |> log_meta_chunks()
    |> Enum.filter(&is_tool_call_args_chunk?/1)
    |> Enum.group_by(& &1.metadata.tool_call_args.index)
    |> Map.new(&assemble_json_fragments/1)
    |> tap(&Logger.debug("Collected arg_fragments: #{inspect(&1)}"))
  end

  defp log_meta_chunks(chunks) do
    meta_chunks = Enum.filter(chunks, &(&1.type == :meta))
    Logger.debug("Meta chunks count: #{length(meta_chunks)}")
    Logger.debug("Meta chunks sample: #{inspect(Enum.take(meta_chunks, 3))}")
    chunks
  end

  defp is_tool_call_args_chunk?(%{type: :meta, metadata: %{tool_call_args: _}}), do: true
  defp is_tool_call_args_chunk?(_), do: false

  defp assemble_json_fragments({index, fragments}) do
    json = Enum.map_join(fragments, "", & &1.metadata.tool_call_args.fragment)
    {index, json}
  end

  defp merge_arguments_into_tool_calls(tool_calls, arg_fragments) do
    tool_calls
    |> Enum.map(&merge_arguments_for_call(&1, arg_fragments))
    |> tap(&Logger.debug("Final tool calls with arguments: #{inspect(&1)}"))
  end

  defp merge_arguments_for_call(call, arg_fragments) do
    case Map.get(arg_fragments, call.index) do
      nil ->
        log_no_fragments(call)
        Map.delete(call, :index)

      json ->
        decode_and_merge_arguments(call, json)
    end
  end

  defp log_no_fragments(call) do
    Logger.debug("No arg fragments for call #{call.name} at index #{call.index}")
  end

  defp decode_and_merge_arguments(call, json) do
    Logger.debug("Decoding JSON for call #{call.name}: #{json}")

    case Jason.decode(json) do
      {:ok, args} ->
        Logger.debug("Decoded args: #{inspect(args)}")
        call |> Map.put(:arguments, args) |> Map.delete(:index)

      {:error, _} ->
        # Keep empty args if invalid JSON
        Map.delete(call, :index)
    end
  end
end
