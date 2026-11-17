# Claude Code launcher aliases (sourced from ~/.zshrc by install.sh)
#
# cc  = Claude Code in "bypass all permissions" mode: no approval prompts for
#       file edits or shell commands. Only use it on a machine and in folders
#       you trust. Add --chrome if you use the Claude in Chrome extension.
alias cc='claude --dangerously-skip-permissions --permission-mode bypassPermissions'

# ca  = the safer everyday alternative: auto mode, still asks for risky actions.
alias ca='claude --permission-mode auto'
