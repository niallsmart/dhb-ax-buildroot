# DVR console command wrapper specification

## Purpose

Provide one reliable way to run a Linux shell command through the persistent
`dvr` UART session when board networking is unavailable or untrustworthy.
The wrapper is for diagnostics, recovery, and provisioning commands; it does
not replace SSH when SSH is working.

## Consumer contract

Given one command and an optional timeout, the wrapper shall:

1. Acquire the existing `dvr` console session without creating a competing
   serial connection.
2. Establish a root Linux shell if the console is at a maintained Linux login
   prompt.
3. Refuse clearly if the console is at U-Boot, vendor Linux, or an unknown
   state. It must not reboot, reset, or otherwise change the board state to
   obtain a shell.
4. Run exactly the requested command once.
5. Return only that command's stdout and stderr, bounded by an unambiguous
   request identifier. It must not include prior pane history, prompts, or the
   command echo.
6. Return the command's remote exit status unchanged.

The wrapper must accept command text without consumers needing to re-escape
shell metacharacters. Supplying the command on standard input is acceptable
and preferred for multi-line diagnostics.

## Output and diagnostics

The normal result shall be line-framed. The wrapper chooses a request
identifier containing only shell-safe alphanumeric characters and uses it in
every marker. Markers occupy a complete line; command output is otherwise
returned unchanged. A section ends at the next marker or end of result.

```text
[dvr <id>] metadata
console state: Linux shell
wall time: <seconds>s
[dvr <id>] stdout
<command stdout>
[dvr <id>] stderr
<command stderr>
[dvr <id>] exit status: <decimal>
[dvr <id>] notes
<optional caller-supplied notes>
```

An empty stdout, stderr, or notes field still has its section marker. The
identifier makes a command-output collision impractical and lets a shell
consumer select one request with `awk` or `sed` without parsing JSON.

`wall time` covers the complete request from acquiring the console through
collecting the terminal result. It includes any login or prompt wait, so it
states the time the caller actually spent rather than only the remote command's
runtime.

Callers may supply optional notes, such as an observation, a follow-up action,
or an explanation of why a hazardous recovery command was authorized. Notes
are copied into the result envelope and artifact metadata, never sent to the
board shell and never merged into stdout or stderr.

Kernel messages and other asynchronous UART output observed while the command
runs are useful evidence, but are not command output. The wrapper shall make
them available separately, either as a distinct result field or an optional
transcript file. A transcript must contain only activity from this request,
not historical console scrollback.

On a timeout, login failure, lost UART session, or unexpected console state,
the wrapper shall return a distinct failure status and the request-local
transcript collected so far. It must never report that the command completed
when the terminal result is ambiguous.

## Operational expectations

- Default timeout: 30 seconds; callers may choose a longer bounded timeout.
- Commands may intentionally alter board state. The wrapper adds no implicit
  recovery action and does not reinterpret a command's meaning.
- A caller can request that stdout, stderr, and the request-local transcript
  are saved under a specified artifact directory.
- Concurrent requests are serialized. A caller receives a clear busy result
  rather than interleaved UART input.
- The wrapper must remain usable after Ethernet has wedged and while the board
  is emitting kernel diagnostics.

## Examples

```sh
dvr-console-command 'uname -r'

dvr-console-command --timeout 10 --artifact-dir artifacts/example <<'EOF'
printf 'DMA Status Register [CSR5]: '
devmem 0x101c1114 32
EOF
```

The first invocation returns the kernel release and its exit status. The
second stores the request-local UART transcript beside the diagnostic artifact
while returning the requested register read without unrelated boot history.
