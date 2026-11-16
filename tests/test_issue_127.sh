#!/usr/bin/env bash
# tests/test_issue_127.sh - Tests for Issue #127
#
# A trailing slash in CAC_GOKAPI_URL produced `//api/...` in every Gokapi
# request URL (live: "HTTP 000 from https://gokapi.bpmspace.org//api/files/add").
# config_load now strips trailing slashes once, and a relative download URL
# from the list response is joined with exactly one slash.
#
# Seams: config_load (a real .env under CAC_CONFIG_DIR), then the Gokapi
# backend functions with a curl stub on PATH that logs the URL it was given
# (its last argument).
#
# shellcheck disable=SC2317  # Test functions are invoked indirectly via run_test

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=tests/test_framework.sh
source "$SCRIPT_DIR/test_framework.sh"

framework_init

# load_with_url <CAC_GOKAPI_URL value>
# Writes a 600 .env with that URL, loads it through config_load and the Gokapi
# backend, and puts a curl stub first on PATH. The stub logs its last argument
# to $CURL_LOG, writes a non-empty file for `-o <file>`, and otherwise answers
# with $STUB_BODY and HTTP $STUB_STATUS.
load_with_url() {
    local cfg="$TEST_TMPDIR/cfg-$RANDOM"
    mkdir -p "$cfg" "$cfg/bin"
    printf 'CAC_BACKEND=gokapi\nCAC_GOKAPI_URL=%s\nCAC_GOKAPI_API_KEY=FIXTURE\n' "$1" > "$cfg/.env"
    chmod 600 "$cfg/.env"

    CURL_LOG="$cfg/curl.log"
    : > "$CURL_LOG"
    cat > "$cfg/bin/curl" <<'EOF'
#!/usr/bin/env bash
out=""
prev=""
for a in "$@"; do
    [[ "$prev" == "-o" ]] && out="$a"
    prev="$a"
done
echo "$prev" >> "$CURL_LOG"
if [[ -n "$out" ]]; then
    echo "zipdata" > "$out"
    exit 0
fi
printf '%s\n%s' "$STUB_BODY" "$STUB_STATUS"
EOF
    chmod 755 "$cfg/bin/curl"
    export CURL_LOG
    export STUB_BODY='[]' STUB_STATUS=200
    PATH="$cfg/bin:$PATH"

    export CAC_CONFIG_DIR="$cfg"
    # shellcheck source=lib/config.sh
    source "$REPO_DIR/lib/config.sh"
    # shellcheck source=lib/utils.sh
    source "$REPO_DIR/lib/utils.sh"
    # shellcheck source=lib/backend_gokapi.sh
    source "$REPO_DIR/lib/backend_gokapi.sh"
    CAC_GOKAPI_MAX_RETRIES=1
    CAC_GOKAPI_RETRY_DELAY=0
    config_load >/dev/null 2>&1
}

# list_url_for <CAC_GOKAPI_URL value>: run `cac list`'s backend call, set URL
# to the URL curl received.
list_url_for() {
    load_with_url "$1"
    backend_gokapi_list >/dev/null 2>&1
    URL=$(tail -n 1 "$CURL_LOG")
}

test_1_trailing_slash() {
    list_url_for "https://h.example/"
    assert_equals "https://h.example/api/files/list" "$URL" "request URL"
}

test_2_double_trailing_slash() {
    list_url_for "https://h.example//"
    assert_equals "https://h.example/api/files/list" "$URL" "request URL"
}

test_3_path_prefix_kept() {
    list_url_for "https://h.example/gk/"
    assert_equals "https://h.example/gk/api/files/list" "$URL" "request URL"
}

# Anti-regression: a URL written without a trailing slash is unchanged.
test_4_no_trailing_slash_unchanged() {
    list_url_for "https://h.example"
    assert_equals "https://h.example" "$CAC_GOKAPI_URL" "CAC_GOKAPI_URL" || return 1
    assert_equals "https://h.example/api/files/list" "$URL" "request URL"
}

# download_url_for <base> <UrlHotlink>: the list answers one bundle whose
# hotlink is relative; set URL to what the download curl received.
download_url_for() {
    load_with_url "$1"
    STUB_BODY="[{\"Id\":\"FIXTURE\",\"Name\":\"b.zip\",\"UrlHotlink\":\"$2\"}]"
    export STUB_BODY
    backend_gokapi_download FIXTURE "$TEST_TMPDIR/out-$RANDOM.zip" >/dev/null 2>&1
    URL=$(tail -n 1 "$CURL_LOG")
}

test_5_relative_download_url_with_leading_slash() {
    download_url_for "https://h.example/" "/hotlink/FIXTURE.zip"
    assert_equals "https://h.example/hotlink/FIXTURE.zip" "$URL" "download URL"
}

test_6_relative_download_url_without_leading_slash() {
    download_url_for "https://h.example/gk/" "hotlink/FIXTURE.zip"
    assert_equals "https://h.example/gk/hotlink/FIXTURE.zip" "$URL" "download URL"
}

# The error message names the URL that was really requested, normalised.
test_7_error_output_shows_normalised_url() {
    load_with_url "https://h.example/"
    export STUB_BODY='oops' STUB_STATUS=500
    local err
    err=$(backend_gokapi_list 2>&1 >/dev/null)
    assert_contains "https://h.example/api/files/list" "$err" "error output" || return 1
    if [[ "$err" == *"//api"* ]]; then
        echo "error output still has //api: $err" >&2
        return 1
    fi
}

echo "========================================"
echo "Issue #127 Tests"
echo "========================================"

run_test "127.1 trailing slash: request URL has one slash" test_1_trailing_slash
run_test "127.2 double trailing slash: request URL has one slash" test_2_double_trailing_slash
run_test "127.3 path prefix with trailing slash is kept" test_3_path_prefix_kept
run_test "127.4 URL without trailing slash is unchanged" test_4_no_trailing_slash_unchanged
run_test "127.5 relative download URL with leading slash" test_5_relative_download_url_with_leading_slash
run_test "127.6 relative download URL without leading slash" test_6_relative_download_url_without_leading_slash
run_test "127.7 error output shows the normalised URL" test_7_error_output_shows_normalised_url

framework_report
