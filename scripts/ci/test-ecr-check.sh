#!/bin/sh
# Feeds fake aws exit codes and stderr texts to ecr-check.sh classify. No AWS, no network.
cd "$(dirname "$0")"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
bad=0
t() {  # t <name> <exit-code> <stderr text> <expected stdout> <expected script exit>
  printf '%s' "$3" > "$T/err"
  out="$(sh ecr-check.sh classify "$2" "$T/err" 2>"$T/msg")"; rc=$?
  if [ "$out" = "$4" ] && [ "$rc" -eq "$5" ]; then echo "   ok    $1  -> stdout='$out' exit=$rc"
  else echo "   FAIL  $1  -> stdout='$out' exit=$rc (wanted '$4' / $5)"; bad=1; fi
}
t "found (aws exit 0)"        0   ""  true  0
t "tag missing"               254 "An error occurred (ImageNotFoundException) when calling the DescribeImages operation: The image with imageId {imageTag:abc1234} does not exist within the repository with name 'campuscart-backend' in the registry with id '111122223333'" false 0
t "repository missing"        254 "An error occurred (RepositoryNotFoundException) when calling the DescribeImages operation: The repository with name 'campuscart-bakend' does not exist in the registry with id '111122223333'" "" 1
t "access denied"             254 "An error occurred (AccessDeniedException) when calling the DescribeImages operation: User is not authorized to perform: ecr:DescribeImages" "" 1
t "expired token"             254 "An error occurred (ExpiredTokenException) when calling the DescribeImages operation: The security token included in the request is expired" "" 1
t "no network"                255 "Could not connect to the endpoint URL: \"https://api.ecr.ap-south-1.amazonaws.com/\"" "" 1
t "no credentials"            253 "Unable to locate credentials. You can configure credentials by running \"aws configure\"." "" 1
t "failure with empty stderr" 255 "" "" 1
# Same logic end to end through the "check" branch, with a fake aws on PATH (still no AWS call).
mkdir -p "$T/bin"
cat > "$T/bin/aws" <<'FAKE'
#!/bin/sh
printf '%s' "$FAKE_STDERR" >&2
exit "${FAKE_RC:-0}"
FAKE
chmod +x "$T/bin/aws"
c() {  # c <name> <fake exit> <fake stderr> <expected stdout> <expected script exit>
  out="$(PATH="$T/bin:$PATH" AWS_REGION=ap-south-1 FAKE_RC="$2" FAKE_STDERR="$3" sh ecr-check.sh check campuscart-backend abc1234 2>/dev/null)"; rc=$?
  if [ "$out" = "$4" ] && [ "$rc" -eq "$5" ]; then echo "   ok    check/$1  -> stdout='$out' exit=$rc"
  else echo "   FAIL  check/$1  -> stdout='$out' exit=$rc (wanted '$4' / $5)"; bad=1; fi
}
c "found"           0   ""  true  0
c "tag missing"     254 "An error occurred (ImageNotFoundException) when calling the DescribeImages operation" false 0
c "access denied"   254 "An error occurred (AccessDeniedException) when calling the DescribeImages operation" "" 1
c "no network"      255 "Could not connect to the endpoint URL" "" 1
[ $bad -eq 0 ] && echo "RESULT: PASS" || echo "RESULT: FAIL"
exit $bad
