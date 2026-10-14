// Kestrel - run LLMs locally on Intel Macs with AMD GPUs
// Copyright (C) 2026 Northlatch Labs <opensource@northlatchlabs.com>
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// The meta-prompt harness (llm-space "prompt space" convention,
/// https://github.com/deer-flow/llm-space, MIT): given a task description —
/// plus an optional existing prompt and the resolved skills markdown list —
/// the latch agent authors a detailed system prompt under the ported
/// llm-space meta-prompt system prompt.
///
/// The harness runs on the latch sidecar with a pinned 600 s budget and no
/// session resume — every run is self-contained. Latch's own permission
/// model confines the run; the prompt-creator role rides as the task's
/// leading instruction, and credentials never touch this process.
///
/// Result contract: the authored prompt text on success; a bilingual failure
/// message on failure or empty output — never a silent engine substitution,
/// never a blank success.
enum MetaPromptService {
    /// Pinned budget for one prompt-authoring run (contract: 600 s). Not
    /// configurable — prompt authoring is a bounded, one-shot generation,
    /// unlike a chat turn.
    static let defaultTimeoutSeconds = 600

    /// System prompt for the prompt-creator role, ported VERBATIM from
    /// llm-space's workspace thread (llm-space, deer-flow/llm-space, MIT
    /// License: https://github.com/deer-flow/llm-space), staged at
    /// .agents/missions/2026-10-03-prompt-space-2/reference/meta-prompt-system.txt
    /// (byte-compared against that file by MetaPromptServiceTests). The
    /// literal carries the 82 staged lines without the file's final LF
    /// terminator.
    static let systemPrompt = """
    Given a task description or existing prompt, produce a detailed system prompt with available tools(if applicable) to guide language model in completing the task effectively.

    # Guidelines

    - The prompt should be in English unless the user explicitly requests otherwise.
    - Understand the Task: Grasp the main objective, goals, requirements, constraints, and expected output.
    - Minimal Changes: If an existing prompt and tools are provided, improve it only if it's simple. For complex prompts, enhance clarity and add missing elements without altering the original structure.
    - Tools: Analyze the task requirements to determine whether specific tools or resources are necessary for effective completion. If tools are required, generate them first, ensuring they align with the task's goals. Then, the system prompt should incorporate the tools and guides the language model in completing the task effectively.
        - The name should adhere to Python function naming conventions, which typically use lowercase letters, underscores to separate words, and avoid special characters or spaces.
        - The name should be descriptive and concise, reflecting the tool's purpose or functionality.
        - Avoid ending the name with "_tool" unless explicitly requested.
    - If you think the task should be in a ReAct manner, you **should** mention "follow the ReAct (Reasoning + Acting) framework to complete the task effectively. "
    - Reasoning Before Conclusions**: Encourage reasoning steps before any conclusions are reached. ATTENTION! If the user provides examples where the reasoning happens afterward, REVERSE the order! NEVER START EXAMPLES WITH CONCLUSIONS!
        - Reasoning Order: Call out reasoning portions of the prompt and conclusion parts (specific fields by name). For each, determine the ORDER in which this is done, and whether it needs to be reversed.
        - Conclusion, classifications, or results should ALWAYS appear last.
    - Examples: Include high-quality examples if helpful, using placeholders [in brackets] for complex elements.
       - What kinds of examples may need to be included, how many, and whether they are complex enough to benefit from placeholders.
    - Clarity and Conciseness: Use clear, specific language. Avoid unnecessary instructions or bland statements.
    - Formatting: Use markdown features for readability. DO NOT USE ``` CODE BLOCKS UNLESS SPECIFICALLY REQUESTED.
      - Use the following format to represent function calls in the `Examples` section.
        <|FunctionCallBegin|>
        [{"name": "func1", "parameters": {...}},
        {"name": "func2", "parameters": {...}]
        <|FunctionCallEnd|>

    - Preserve User Content: If the input task or prompt includes extensive guidelines or examples, preserve them entirely, or as closely as possible. If they are vague, consider breaking down into sub-steps. Keep any details, guidelines, examples, variables, or placeholders provided by the user.
    - Constants: DO include constants in the prompt, as they are not susceptible to prompt injection. Such as guides, rubrics, and examples.
    - Output Format: Explicitly the most appropriate output format, in detail. This should include length and syntax (e.g. short sentence, paragraph, JSON, etc.)
        - For tasks outputting well-defined or structured data (classification, JSON, etc.) bias toward outputting a JSON.
        - JSON should never be wrapped in code blocks (```) unless explicitly requested.

    The final prompt you output should adhere to the following structure below. Do not include any additional commentary, only output the completed system prompt. SPECIFICALLY, do not include any additional messages at the start or end of the prompt. (e.g. no "---")


    # Tools [optional]

    [{
      "name": "function_name",
      "description": "Function description.",
      "strict": true,
      "parameters": {
        "type": "object",
        "required": ["parameter1", "parameter2"],
        "properties": {
          "parameter1": {
            "type": "data_type",
            "description": "Description of parameter1"
          },
          "parameter2": {
            "type": "data_type",
            "description": "Description of parameter2"
          }
        },
        "additionalProperties": false
      }
    }]

    # System Prompt

    [Concise instruction describing the task - this should be the first line in the prompt, no section header]

    [Additional details as needed.]

    [Optional sections with headings or bullet points for detailed steps.]

    # Steps [optional]

    [optional: a detailed breakdown of the steps necessary to accomplish the task. Use the format `tool_name(args...)` to represent tool calls.]

    # Output Format

    [Specifically call out how the output should be formatted, be it response length, structure e.g. JSON, markdown, tool_calls, etc]


    # Examples [optional]

    [Optional: 1-3 well-defined examples with placeholders if necessary. Clearly mark where examples start and end, and what the input and output are. User placeholders as necessary.]
    [If the examples are shorter than what a realistic example is expected to be, make a reference with () explaining how real examples should be longer / shorter / different. AND USE PLACEHOLDERS! ]

    # Notes [optional]

    [optional: edge cases, details, and an area to call or repeat out specific important considerations]
    """

    /// Bilingual failure text for an empty (or whitespace-only) task
    /// description. The guard runs before latch is ever launched — there is
    /// nothing to author from, and no silent fallback is allowed.
    static let emptyTaskMessage =
        "La descripción de la tarea está vacía: no hay nada que convertir en prompt. "
            + "Describe la tarea y vuelve a intentarlo. / The task description is "
            + "empty: there is nothing to turn into a prompt. Describe the task "
            + "and try again."

    /// Bilingual failure text for a clean exit with no visible output —
    /// mirrors the chat empty-success guard; never a blank result.
    static let emptyReplyMessage =
        "latch completó la creación del prompt sin producir texto visible. / "
            + "latch completed the prompt-authoring run without producing visible text."

    /// Bilingual failure text for an abnormal exit (mirrors the chat path).
    static func exitMessage(status: Int32) -> String {
        "latch terminó de forma anómala (estado \(status)). / latch exited abnormally (status \(status))."
    }

    /// Builds the latch argv for one prompt-authoring run: the prompt-creator
    /// system prompt leads the task so the authored output is the prompt
    /// itself, and the assembled task variables follow it. No resume flag is
    /// ever added, so the run is self-contained.
    static func argv(prompt: String) -> [String] {
        [LatchDelegateService.binaryPath, "-p",
         systemPrompt + "\n\n" + prompt]
    }

    /// Feeds the run's variables the way LLM Space feeds its prompt-space
    /// template variables: the required task description first, then the
    /// optional variables under fixed headings — "Existing prompt to
    /// improve:" and "Available skills:" — each included only when non-empty
    /// (whitespace-only counts as absent). The skills list arrives as the
    /// resolved markdown list (e.g. "- name: description" lines).
    static func assembledPrompt(taskDescription: String, existingPrompt: String?,
                                skillsList: String) -> String {
        var prompt = taskDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        let existing = existingPrompt?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !existing.isEmpty {
            prompt += "\n\nExisting prompt to improve:\n" + existing
        }
        let skills = skillsList.trimmingCharacters(in: .whitespacesAndNewlines)
        if !skills.isEmpty {
            prompt += "\n\nAvailable skills:\n" + skills
        }
        return prompt
    }

    /// Runs the task description (plus optional existing prompt and the
    /// resolved skills markdown list) through latch with the prompt-creator
    /// system prompt leading the task and a 600 s budget. Returns the
    /// authored prompt text, or a bilingual failure message on failure or
    /// empty — never a silent fallback.
    ///
    /// Deltas stream through `onOutput` into a StreamBuffer — the same
    /// snapshot-replace buffer the chat's latch path pumps into its live
    /// view — so the latest visible snapshot is always the replaced-whole
    /// buffer state, never an append-only pile. There is no UI pump here
    /// (the pinned contract returns a single String), so the buffer exists
    /// only to keep the pump contract identical to the chat turn.
    static func run(taskDescription: String, existingPrompt: String?,
                    skillsList: String) async -> String {
        let task = taskDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !task.isEmpty else { return Self.emptyTaskMessage }
        let prompt = Self.assembledPrompt(taskDescription: task,
                                          existingPrompt: existingPrompt,
                                          skillsList: skillsList)
        let buffer = StreamBuffer()
        let outcome = await LatchDelegateService.runStreaming(
            argv: Self.argv(prompt: prompt),
            // Prompt authoring binds no working directory: the run must not
            // touch any folder the caller did not name in the task.
            workingDirectory: nil,
            timeout: Self.defaultTimeoutSeconds,
            onLaunch: nil,
            onOutput: { _, fullSoFar in
                buffer.write(reasoning: "", visible: fullSoFar, speed: nil)
            })
        buffer.finish()
        switch outcome {
        case .completed(let output):
            let produced = output.trimmingCharacters(in: .whitespacesAndNewlines)
            if produced.isEmpty {
                // Empty-success guard: surface the failure — never a blank result.
                return Self.emptyReplyMessage
            }
            return output
        case .exited(let status, let output):
            let partial = output.trimmingCharacters(in: .whitespacesAndNewlines)
            return partial.isEmpty
                ? Self.exitMessage(status: status)
                : partial + "\n\n" + Self.exitMessage(status: status)
        case .failed(let reason):
            // Bilingual already (timeout budget, launch failure, bounded
            // stderr tail) — pass it through untouched.
            return reason
        }
    }
}
