# Shared terminal colors and log helpers for provision scripts.
# Source from scripts/provision.sh — do not execute directly.

if [[ -t 1 ]]; then
  GREEN=$'\033[1;32m'
  CYAN=$'\033[1;36m'
  YELLOW=$'\033[1;33m'
  RED=$'\033[1;31m'
  BLUE=$'\033[1;34m'
  BOLD_RED=$'\033[1;31m'
  BOLD_CYAN=$'\033[1;36m'
  BOLD_BLACK=$'\033[1;30m'
  RESET=$'\033[0m'
  H_CYAN=$'\033[0;36m'
  H_GREEN=$'\033[0;32m'
  H_YELLOW=$'\033[0;33m'
  H_RED=$'\033[0;31m'
  H_DIM=$'\033[2;90m'
else
  GREEN=""; CYAN=""; YELLOW=""; RED=""; BLUE=""
  BOLD_RED=""; BOLD_CYAN=""; BOLD_BLACK=""; RESET=""
  H_CYAN=""; H_GREEN=""; H_YELLOW=""; H_RED=""; H_DIM=""
fi

log_info()          { printf "${CYAN}[INFO]${RESET} %s\n" "$*"; }
log_success()       { printf "${GREEN}[SUCCESS]${RESET} %s\n" "$*"; }
log_warning()       { printf "${YELLOW}[WARN]${RESET} %s\n" "$*"; }
log_error()         { printf "\n${RED}[ERROR]${RESET} %s\n" "$*" >&2; }
log_step()          { printf "\n${BLUE}▶ %s\n${RESET}\n" "$*"; }
log_check_success() { printf "${GREEN}[SUCCESS]:${RESET} %s\n" "$*"; }
log_check_failed()  { printf "\n${RED}[FAILED]:${RESET} %s\n" "$*" >&2; }

banner_cmd() {
  printf "     ${H_GREEN}%s${RESET}\n" "$1"
}

usage_help_line() {
  local indent="${2:-  }"
  printf "${indent}${H_GREEN}%s${RESET}\n" "$1"
}

usage_synopsis_example() {
  printf "  ${YELLOW}e.g.${RESET} ${H_GREEN}%s${RESET}\n" "$1"
}

print_module_header() {
  printf "\n"
  printf "${H_DIM}──────────────────────────────────────────────────${RESET}\n"
  printf "${BOLD_CYAN}%s${RESET}\n" "$1"
  printf "${H_DIM}──────────────────────────────────────────────────${RESET}\n\n"
}

print_prerequisites_heading() {
  printf "${YELLOW}Prerequisites${RESET} ${H_CYAN}%s${RESET}\n\n" "$1"
}
