# Codex approvals in Atoll

When Atoll receives a local Codex shell or file-edit approval request, the island expands to display the request inside its existing window, using the same shape and open/close animations as other Atoll actions. Review the working directory and exact tool arguments before selecting **Allow once**, **Deny**, or **Respond in Codex**. Atoll sends a decision only after an explicit click. Other approval types, including general ChatGPT confirmation cards, stay in their original interface.

## Enable the hook

Use a local Codex or ChatGPT Work session that supports the `PermissionRequest` hook. Atoll and the hook must run on the same Mac as the same macOS user.

Copy `scripts/atoll-codex-approval.py` to a stable path you control. Add the following entry to your user `~/.codex/hooks.json`, merging it with any existing `PermissionRequest` entries. Replace the script path with its absolute path.

```json
{
  "hooks": {
    "PermissionRequest": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "/usr/bin/python3 '/absolute/path/atoll-codex-approval.py'",
            "timeout": 85,
            "statusMessage": "Waiting for your decision in Atoll"
          }
        ]
      }
    ]
  }
}
```

Review and trust the hook in Codex. For shells that have no trusted hook or for requests outside the supported tool types, Codex handles approval normally. The original approval also appears after selecting **Respond in Codex**, if Atoll is unavailable, or after 75 seconds without a decision. The hook does not persist blanket approvals or change Codex's approval policy.

The request and reply are exchanged through a private local directory below `~/Library/Application Support/Atoll/CodexApprovals`. The hook removes its request directory when it exits. Keep the script and configuration under your own user account.

[Codex hook documentation](https://learn.chatgpt.com/docs/hooks#permissionrequest)

## Presentation behavior

The decision stays visible until you choose an action, the request expires, or the Mac locks. Hovering away does not dismiss it. After a decision, Atoll restores the previous open/closed state. A screenshot import cannot replace an active approval. The hook is acknowledged only after the request view is mounted in a visible island window; if it cannot be shown, the normal Codex fallback remains available.
