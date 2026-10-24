#!/bin/bash
# =====================================================================================================================
# nai-on-nkp.sh - single-node Nutanix Kubernetes Platform (NKP) + Nutanix Enterprise AI (NAI), air-gapped bundles.
# Author: Manmohan Brahma
#
#   sudo ./nai-on-nkp.sh               install (asks its questions first, then runs unattended; asks before reboots)
#   sudo ./nai-on-nkp.sh --uninstall   remove NKP + NAI, every modification and GPU driver it installed (OS default)
#   sudo ./nai-on-nkp.sh --adopt       record an existing hand-built NKP + NAI lab so --uninstall can remove it
#   sudo ./nai-on-nkp.sh --status      progress and recorded host changes
#   sudo ./nai-on-nkp.sh --plan        read-only preview of what --uninstall would remove and keep
#   sudo ./nai-on-nkp.sh --check       read-only host and GPU check
#
# Stacks (chosen at the start):
#   stock  Single-node NKP + NAI exactly as shipped. x86_64 CPU, plus NVIDIA GPUs when present (host driver from the
#          Ubuntu archive, NVIDIA GPU Operator from NKP). No modifications.
#   moded  Stock + the modifications that let NAI serve on AMD GPUs: AMD GPU Operator 1.5.1 as a Kommander catalog
#          app (PCI-filtered device plugin, ECC threshold), ROCm vLLM image wrapped for NAI, patched NAI chart, API
#          and UI, the nai-amd-shim admission webhook, AMD catalog runtimes and AMD GPU metrics in NAI. Non-compute
#          AMD GPUs (e.g. a display W6400) are isolated with vfio-pci (one reboot, asked first).
# Questions: NKP bundle, NAI image bundle and NAI Helm charts (download link or path), stack, installation storage
# (bundles, registry, local volumes) and model storage (NFS share for NAI models), MetalLB address range.
# Download links are checked as you paste them and downloaded after the final confirmation (progress bar, resumable).
#
# Every change to this host is recorded in /var/lib/nai-nkp/manifest; --uninstall reverses exactly those changes,
# removes the packages this script installed (never one the OS had before) and asks separately before deleting the
# model storage. Tested: Ubuntu 26.04.1 (kernel 7.0), NKP 2.18.0, NAI 2.8.1, RTX A6000, Radeon Pro W7900.
# =====================================================================================================================
set -eEuo pipefail
trap 'rc=$?; [ "$BASH_SUBSHELL" = 0 ] && echo "${c_r:-}ERROR: unexpected failure (exit $rc) at line $LINENO: $BASH_COMMAND - run the script again to continue from this stage${c_0:-}" | tee -a "${TLOG:-/dev/null}" >&2' ERR
umask 022
SELF=$(readlink -f "$0"); KIT=$(dirname "$SELF"); ASSETS=$KIT/assets

STATE=${STATE:-/var/lib/nai-nkp}            # answers, manifest, logs, done markers (root only)
CONF=$STATE/answers.conf
MANIFEST=$STATE/manifest
DONE=$STATE/done
LOG=$STATE/run.log
TLOG=$LOG                                     # where on-screen lines are copied (/dev/null when stdout is the log)
RESUME_UNIT=/etc/systemd/system/nai-nkp-resume.service
MARK="nai-nkp"                                # marker for blocks this script adds to shared files (fstab, exports)

TESTED_NKP=2.18.0; TESTED_NAI=2.8.1
REG_PORT=${REG_PORT:-5000}
LOCAL_PV_COUNT=${LOCAL_PV_COUNT:-20}          # bind-mounted local volumes for NKP platform apps (/mnt/disks)
NAI_PV_COUNT=${NAI_PV_COUNT:-8}               # local volumes for NAI databases and metrics (storage class nai-local)
KUBELET_MAX_PODS=${KUBELET_MAX_PODS:-250}
POD_CIDR=${POD_CIDR:-192.168.0.0/16}          # NKP (Calico) pod network: NFS clients
HELM_VERSION=${HELM_VERSION:-v3.19.0}
CSI_NFS_VERSION=${CSI_NFS_VERSION:-4.13.5}
AMD_OPERATOR_VERSION=${AMD_OPERATOR_VERSION:-v1.5.1}
AMD_ECC_UMC_THRESHOLD=${AMD_ECC_UMC_THRESHOLD:-4000000000}
AMD_SUPPORTED_IDS=${AMD_SUPPORTED_IDS:-"7448 744a 7449 745e 744c 7551 74a1 74a5 75a3"}   # W7900/W7800/RX7900/R9700/MI300-355
ROCM_VLLM_BASE=${ROCM_VLLM_BASE:-docker.io/rocm/vllm:rocm10.1.0_ubuntu24.04_py3.14-pytorch_2.13.0_vllm-0.29.0}
ROCM_VLLM_IMAGE=${ROCM_VLLM_IMAGE:-docker.io/rocm/nai-vllm-rocm}
ROCM_VLLM_TAG=${ROCM_VLLM_TAG:-v0.29.0-rocm10.1.0}
INTERACTIVE=1; [ -t 0 ] || INTERACTIVE=0

# ---------------------------------------------------------------- output, prompts, state
c_b=$'\e[1m'; c_g=$'\e[32m'; c_y=$'\e[33m'; c_r=$'\e[31m'; c_0=$'\e[0m'
log()  { [ "$TLOG" = /dev/null ] || mkdir -p "$STATE"; echo "${c_b}$(date '+%F %T') == $*${c_0}" | tee -a "$TLOG"; }
ok()   { echo "  ${c_g}[ok]${c_0} $*" | tee -a "$TLOG"; }
warn() { echo "  ${c_y}[!]${c_0} $*" | tee -a "$TLOG"; }
die()  { echo "${c_r}ERROR: $*${c_0}" | tee -a "$TLOG" >&2; exit 1; }
ask()  { local v=""; [ $INTERACTIVE = 1 ] && read -r -p "$1${2:+ [$2]}: " v </dev/tty; echo "${v:-${2:-}}"; }
yesno() { local a; a=$(ask "$1 (y/n)" "${2:-y}"); [[ $a =~ ^[Yy] ]]; }
ask_int() { local v; while :; do v=$(ask "$1" "$2"); [[ $v =~ ^[0-9]+$ ]] && [ "$v" -ge "$3" ] && [ "$v" -le "$4" ] && { echo "$v"; return; }
            echo "   enter a number from $3 to $4" >/dev/tty; done; }
valid_ip() { python3 -c "import ipaddress,sys;ipaddress.IPv4Address(sys.argv[1])" "$1" 2>/dev/null; }
save() { touch "$CONF"; grep -v "^$1=" "$CONF" > "$CONF.tmp" || true; printf '%s=%q\n' "$1" "$2" >> "$CONF.tmp"; mv "$CONF.tmp" "$CONF"; chmod 600 "$CONF"; }
rec()  { grep -qxF "$*" "$MANIFEST" 2>/dev/null || echo "$*" >> "$MANIFEST"; }      # record a host change for --uninstall
done_() { [ -f "$DONE/$1" ]; }
stage() { local s=$1; shift; done_ "$s" && return 0; log "stage: $s"; "$@"; touch "$DONE/$s"; }
human() { python3 -c "import sys;b=float(sys.argv[1]);print(next(f'{b/1024**i:.1f} {u}' for i,u in reversed(list(enumerate(['B','KB','MB','GB','TB']))) if b>=1024**i or i==0))" "${1:-0}"; }
free_gb() { local d=$1; while [ ! -d "$d" ]; do d=$(dirname "$d"); done; df -BG --output=avail "$d" | tail -1 | tr -dc 0-9; }
largest_fs() { df -BG --output=avail,target -x tmpfs -x devtmpfs -x overlay -x squashfs -x efivarfs 2>/dev/null | tail -n +2 | sort -n | tail -1 | awk '{print $2}'; }
host_ip() { ip -4 route get "${1:-1.1.1.1}" 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}'; }
port_free() { ! ss -ltnH "sport = :$1" 2>/dev/null | grep -q .; }
user_home() { getent passwd "$1" | cut -d: -f6; }

# record a file before changing it (restored by --uninstall); new files are recorded as FILE
backup_file() { local f=$1 b; b=$STATE/backup$(echo "$f" | tr / _)
  [ -e "$b" ] && return 0
  if [ -e "$f" ]; then cp -p "$f" "$b"; rec "RESTORE $b $f"; else rec "FILE $f"; fi; }
# marker-delimited block in a shared file (fstab, exports): added once, removed exactly by --uninstall
block_set() { local f=$1 tag=$2 body=$3
  touch "$f"; sed -i "\|^# BEGIN $MARK $tag\$|,\|^# END $MARK $tag\$|d" "$f"
  printf '# BEGIN %s %s\n%s\n# END %s %s\n' "$MARK" "$tag" "$body" "$MARK" "$tag" >> "$f"; rec "BLOCK $f $tag"; }

# ---------------------------------------------------------------- packages (recorded; removed safely on uninstall)
pkg_list() { dpkg-query -W -f='${Package}\n' | LC_ALL=C sort -u; }
pkg_new()  { pkg_list | LC_ALL=C comm -13 "$1" -; }
apt_install() {   # host apt may be locked to NKP's offline repo: use a private Ubuntu archive source then (never /etc/apt)
  local p miss=0 before=$STATE/pkgs.before.$$
  pkg_list > "$before"; export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq >/dev/null 2>&1 || true
  for p in "$@"; do apt-cache policy "$p" 2>/dev/null | grep -q 'Candidate: [0-9]' || miss=1; done
  if [ $miss = 0 ]; then apt-get install -y -qq --no-install-recommends "$@"
  else
    local d=$STATE/apt code; code=$(. /etc/os-release; echo "${VERSION_CODENAME:-$UBUNTU_CODENAME}")
    mkdir -p "$d/lists/partial" "$d/archives/partial"; id _apt >/dev/null 2>&1 && chown -R _apt "$d/lists/partial" "$d/archives/partial"
    { echo "deb http://archive.ubuntu.com/ubuntu $code main universe restricted multiverse"
      echo "deb http://archive.ubuntu.com/ubuntu $code-updates main universe restricted multiverse"
      echo "deb http://security.ubuntu.com/ubuntu $code-security main universe restricted multiverse"; } > "$d/sources.list"
    local o=(-o Dir::Etc::SourceList="$d/sources.list" -o Dir::Etc::SourceParts=- -o Dir::State::Lists="$d/lists" -o Dir::Cache::Archives="$d/archives")
    apt-get "${o[@]}" update -qq || die "cannot reach archive.ubuntu.com"
    apt-get "${o[@]}" install -y -qq --no-install-recommends --no-upgrade "$@"
  fi
  pkg_new "$before" | while read -r p; do rec "PKG $p"; done; rm -f "$before"
}

# ---------------------------------------------------------------- downloads
url_size() {   # bytes behind a download link (1-byte ranged GET: signed links often refuse HEAD); exit 1 = unusable
  python3 - "$1" <<'PY'
import sys, urllib.request, urllib.error
try:
    r = urllib.request.urlopen(urllib.request.Request(sys.argv[1], headers={"Range": "bytes=0-0"}), timeout=30)
    cr, cl = r.headers.get("Content-Range", ""), r.headers.get("Content-Length", "")
    print(cr.rsplit("/", 1)[1] if "/" in cr else (cl if r.status == 200 else "0"))
except urllib.error.HTTPError as e:
    print(f"HTTP {e.code}" + (" - link expired or not authorised" if e.code in (401, 403) else ""), file=sys.stderr); sys.exit(1)
except Exception as e:
    print(f"unreachable: {e}", file=sys.stderr); sys.exit(1)
PY
}

download() {   # url dst: resumable download with a progress bar (python: works before curl/wget are installed)
  python3 - "$1" "$2" <<'PY'
import os, sys, time, urllib.request
url, dst = sys.argv[1], sys.argv[2]
part, name = dst + ".part", os.path.basename(url.split("?")[0])
tty = sys.stderr.isatty()
def fmt(b): return f"{b/1e9:.2f} GB" if b >= 1e9 else f"{b/1e6:.1f} MB"
for attempt in range(1, 8):
    have = os.path.getsize(part) if os.path.exists(part) else 0
    try:
        r = urllib.request.urlopen(urllib.request.Request(url, headers={"Range": f"bytes={have}-"} if have else {}), timeout=60)
        if have and r.status != 206: have = 0
        cr = r.headers.get("Content-Range", "")
        total = int(cr.rsplit("/", 1)[1]) if "/" in cr else have + int(r.headers.get("Content-Length") or 0)
        done, t0, start, last, step = have, time.time(), have, 0, -1
        def show(final=False):
            global step
            rate = (done - start) / max(time.time() - t0, 1e-3)
            pct = done / total * 100 if total else 0
            eta = (total - done) / rate if rate and total else 0
            if tty:
                bar = "#" * int(pct / 2.5) + "-" * (40 - int(pct / 2.5))
                sys.stderr.write(f"\r   [{bar}] {pct:5.1f}%  {fmt(done)} / {fmt(total)}  {rate/1e6:6.1f} MB/s  "
                                 + (f"done in {int((time.time()-t0)//60)}m{int((time.time()-t0)%60):02d}s\n" if final else f"ETA {int(eta//60)}m{int(eta%60):02d}s "))
            elif final or int(pct // 10) != step:
                step = int(pct // 10); print(f"   {name}: {pct:.0f}% ({fmt(done)} / {fmt(total)}, {rate/1e6:.1f} MB/s)", file=sys.stderr)
        with open(part, "ab" if have else "wb") as f:
            while True:
                b = r.read(4 << 20)
                if not b: break
                f.write(b); done += len(b)
                if time.time() - last >= 0.5: last = time.time(); show()
        show(final=True)
        if total and done != total: raise IOError(f"incomplete: {done} of {total} bytes")
        os.replace(part, dst); sys.exit(0)
    except SystemExit: raise
    except Exception as e:
        if tty: sys.stderr.write("\n")
        print(f"   {name}: {e} - retry {attempt}/7 (resumes where it stopped)", file=sys.stderr); time.sleep(min(60, 5 * attempt))
sys.exit(f"download failed: {name}")
PY
}

# ---------------------------------------------------------------- reboots (never without consent)
install_resume_unit() {
  cat > "$RESUME_UNIT" <<EOF
[Unit]
Description=Resume nai-on-nkp setup after reboot
After=network-online.target
Wants=network-online.target
[Service]
Type=oneshot
ExecStart=$SELF --resume
StandardOutput=journal+console
TimeoutStartSec=0
[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload; systemctl enable nai-nkp-resume.service >/dev/null 2>&1; rec "FILE $RESUME_UNIT"
}
reboot_ask() {   # consent was asked with the questions (REBOOT_OK); the background job never reboots without it
  install_resume_unit; warn "a reboot is needed to $1"
  if [ "${REBOOT_OK:-no}" = yes ]; then
    echo "  rebooting in 10 s (agreed at the start); the setup continues automatically after the reboot" | tee -a "$TLOG"; sync; sleep 10; systemctl reboot; exit 0
  fi
  if [ $INTERACTIVE = 1 ] && yesno "Reboot now? The setup continues automatically after the reboot" y; then
    echo "  follow it after the reboot with: journalctl -fu nai-nkp-resume   or   sudo tail -f $LOG"; sync; systemctl reboot; exit 0
  fi
  echo "  Not rebooting. Reboot when convenient (sudo reboot); the setup then continues on its own, or run this script again."
  exit 0
}

# ---------------------------------------------------------------- kubernetes helpers
kc() { kubectl --kubeconfig "$KCFG" "$@"; }
hl() { helm --kubeconfig "$KCFG" "$@"; }
wait_for() {   # description timeout-seconds interval shell-condition
  local d=$1 t=$2 i=$3 c=$4 s=$SECONDS
  until bash -c "$c" >/dev/null 2>&1; do
    [ $((SECONDS - s)) -ge "$t" ] && { warn "$d: not reached within $((t / 60)) min"; return 1; }
    sleep "$i"
  done; ok "$d"; }
pods_ready() { ! kc get pods -n "$1" --no-headers 2>/dev/null | awk '$3 != "Completed" && $3 != "Succeeded" && ($3 != "Running" || split($2, r, "/") && r[1] != r[2])' | grep -q .; }
reg_has() { skopeo inspect --tls-verify=false "docker://$REG/$1" >/dev/null 2>&1; }
retry() {   # cmd...: up to 4 tries, 15/30/45 s apart (rides out DNS and registry blips)
  local _try=1; until "$@"; do [ $_try -ge 4 ] && return 1; warn "attempt $_try failed, retrying in $((_try * 15)) s: $*"; sleep $((_try * 15)); _try=$((_try + 1)); done; }
mirror_image() { reg_has "${2:-${1#*/}}" || retry skopeo copy -q --all --dest-tls-verify=false "docker://$1" "docker://$REG/${2:-${1#*/}}"; }
hinst() {   # release chart namespace timeout [helm args]: install/upgrade, wait until ready; on failure show why
  local r=$1 c=$2 n=$3 t=$4; shift 4
  hl upgrade --install "$r" "$c" -n "$n" --create-namespace --wait --timeout "$t" "$@" >/dev/null 2>"$WORK/helm-$r.err" && return 0
  { echo "  component '$r' (namespace $n) did not become ready within $t:"
    tail -3 "$WORK/helm-$r.err" | sed 's/^/    helm: /'
    kc get pods -n "$n" --no-headers 2>/dev/null | awk '$3 != "Running" && $3 != "Completed" {print "    pod: " $1 "  " $3}'
    kc get events -n "$n" --field-selector type=Warning --sort-by=.lastTimestamp --no-headers 2>/dev/null | tail -5 | cut -c1-220 | sed 's/^/    event: /'
  } | tee -a "$TLOG"
  die "component $r failed (details above); fix the cause and run the script again to continue"
}
registry_ensure() {
  curl -fsS -m 5 "http://$REG/v2/" >/dev/null 2>&1 && return 0
  warn "registry $REG is not answering; restarting it"; podman start nkp-registry >/dev/null 2>&1 || true; sleep 3
  curl -fsS -m 5 "http://$REG/v2/" >/dev/null 2>&1 || die "registry $REG is down (podman ps -a; podman logs nkp-registry)"
}

# ---------------------------------------------------------------- GPU discovery
pci_ids() { local v d; v=$(<"/sys/bus/pci/devices/$1/vendor"); d=$(<"/sys/bus/pci/devices/$1/device"); echo "${v#0x}:${d#0x}"; }
pci_name() { lspci -s "$1" 2>/dev/null | sed -E 's/^[^ ]+ [^:]+: //; s/ \(rev [0-9a-f]+\)$//' | cut -c1-70; }
drv() { basename "$(readlink /sys/bus/pci/devices/$1/driver 2>/dev/null)" 2>/dev/null || true; }
slot_functions() { local f; for f in /sys/bus/pci/devices/${1%.*}.*; do basename "$f"; done; }
discover_gpus() {   # NV_BDFS, AMD_BDFS (all AMD display/compute devices)
  NV_BDFS=(); AMD_BDFS=(); local b cls
  for b in $(ls /sys/bus/pci/devices); do
    cls=$(<"/sys/bus/pci/devices/$b/class")
    [[ $cls == 0x0300* || $cls == 0x0302* || $cls == 0x0380* || $cls == 0x1200* ]] || continue
    case $(pci_ids "$b") in 10de:*) NV_BDFS+=("$b") ;; 1002:*) AMD_BDFS+=("$b") ;; esac
  done
}
amd_supported() { [[ " $AMD_SUPPORTED_IDS " == *" $(pci_ids "$1" | cut -d: -f2) "* ]]; }
gpu_report() {
  discover_gpus; local b i=0
  echo "  CPU     : $(lscpu | awk -F: '/Model name/{gsub(/^ +/,"",$2);print $2; exit}'), $(nproc --all) threads"
  echo "  Memory  : $(free -g | awk '/Mem:/{print $2" GB total, "$7" GB available"}')"
  if [ ${#NV_BDFS[@]} = 0 ]; then echo "  NVIDIA  : none"; fi
  for b in "${NV_BDFS[@]}"; do echo "  NVIDIA  : $b  $(pci_name "$b")  driver $(drv "$b")"; done
  if [ ${#AMD_BDFS[@]} = 0 ]; then echo "  AMD     : none"; fi
  for b in "${AMD_BDFS[@]}"; do i=$((i + 1))
    printf "  AMD %-4s: %s  %s  driver %s%s\n" "$i)" "$b" "$(pci_name "$b")" "$(drv "$b")" "$(amd_supported "$b" && echo '  [compute: supported]' || echo '  [not a compute target]')"
  done
  command -v nvidia-smi >/dev/null && nvidia-smi -L >/dev/null 2>&1 && echo "  NVIDIA driver: $(nvidia-smi --query-gpu=driver_version --format=csv,noheader | head -1) (working)" || true
}

# ---------------------------------------------------------------- 1. questions (all asked up front)
ask_src() {   # VAR label: download link (checked now) or local path
  local src n=0 size
  while :; do
    src=$(ask "   $2: download link or path")
    if [[ $src =~ ^https?:// ]]; then
      if size=$(url_size "$src"); then ok "link works: $(basename "${src%%\?*}"), $(human "$size")"; save "${1}_BYTES" "$size"; break; fi
    elif [ -f "$src" ]; then ok "$src ($(human "$(stat -c %s "$src")"))"; break
    else echo "   not a link and no such file: $src" >/dev/tty; fi
    n=$((n + 1)); [ $n -ge 3 ] && die "no usable $2"; echo "   try again (a fresh link from the Nutanix portal if it expired)" >/dev/tty
  done
  printf -v "$1" '%s' "$src"; save "$1" "$src"
}

ask_dir() {   # VAR question default need-GB
  local d; d=$(ask "$2" "$3"); d=${d%/}; [[ $d == /* ]] || die "give an absolute path"
  [ "$(free_gb "$d")" -ge "$4" ] && ok "$d: $(free_gb "$d") GB free" || warn "$d has only $(free_gb "$d") GB free (about $4 GB needed)"
  printf -v "$1" '%s' "$d"; save "$1" "$d"
}

inputs() {
  [ $INTERACTIVE = 1 ] || die "the setup questions have not been answered; run interactively: sudo $SELF"
  echo; echo "${c_b}NKP + Nutanix Enterprise AI (single node)${c_0} - all questions first, then it runs unattended."
  . /etc/os-release
  [[ $ID == ubuntu ]] || die "$PRETTY_NAME is not supported (Ubuntu 22.04, 24.04 or 26.04)"
  INSTALL_USER=${SUDO_USER:-}; [ -n "$INSTALL_USER" ] && [ "$INSTALL_USER" != root ] \
    || INSTALL_USER=$(ask "   Non-root user with sudo that NKP connects as over SSH"); id "$INSTALL_USER" >/dev/null 2>&1 || die "no user $INSTALL_USER"
  save INSTALL_USER "$INSTALL_USER"

  echo; echo "${c_b}Bundles${c_0} (Nutanix portal: Downloads > NKP and > Nutanix Enterprise AI; links expire, paths are fine too)"
  ask_src NKP_SRC "NKP air-gapped bundle (nkp-air-gapped-bundle_v*_linux_amd64.tar.gz)"
  ask_src NAI_TAR_SRC "NAI air-gapped image bundle (nai-v*.tar)"
  ask_src NAI_CHARTS_SRC "NAI Helm charts (nai-helm-charts-*.tar)"
  NKP_VERSION=$(basename "${NKP_SRC%%\?*}" | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+' | head -1 | tr -d v); NKP_VERSION=${NKP_VERSION:-$TESTED_NKP}
  NAI_VERSION=$(basename "${NAI_TAR_SRC%%\?*}" | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+' | head -1 | tr -d v); NAI_VERSION=${NAI_VERSION:-$TESTED_NAI}
  save NKP_VERSION "$NKP_VERSION"; save NAI_VERSION "$NAI_VERSION"
  [ "$NKP_VERSION/$NAI_VERSION" = "$TESTED_NKP/$TESTED_NAI" ] && ok "NKP $NKP_VERSION + NAI $NAI_VERSION (tested combination)" \
    || warn "NKP $NKP_VERSION + NAI $NAI_VERSION: tested is NKP $TESTED_NKP + NAI $TESTED_NAI (the moded stack refuses other NAI builds)"

  echo; echo "${c_b}This host${c_0}"; gpu_report
  echo; echo "${c_b}Stack${c_0}"
  echo "     1) stock  NKP + NAI as shipped: x86_64 CPU and NVIDIA GPUs (no modifications)"
  echo "     2) moded  stock + AMD GPU support for NAI (AMD operator, patched NAI, ROCm vLLM, webhook)"
  local m; m=$(ask "   Choose 1 or 2" 1); case $m in 1|stock) STACK=stock ;; 2|moded) STACK=moded ;; *) die "choose 1 or 2" ;; esac
  save STACK "$STACK"

  NV_COUNT=${#NV_BDFS[@]}; save NV_COUNT "$NV_COUNT"
  if [ "$NV_COUNT" -gt 0 ]; then
    if nvidia-smi -L >/dev/null 2>&1; then ok "NVIDIA: $NV_COUNT GPU(s), host driver working - used by the NVIDIA GPU Operator"
    else warn "NVIDIA: $NV_COUNT GPU(s) without a working driver - the NVIDIA driver is installed from the Ubuntu archive (a reboot may be needed, asked first)"; fi
  else ok "no NVIDIA GPU: NAI endpoints run on CPU$([ $STACK = moded ] && echo ' and AMD GPUs')"; fi

  AMD_TARGETS=""; AMD_OTHERS=""; AMD_OTHER_POLICY=none
  if [ $STACK = moded ]; then
    local b i sel def=""; i=0
    for b in "${AMD_BDFS[@]}"; do i=$((i + 1)); amd_supported "$b" && def="${def:+$def,}$i"; done
    [ -n "$def" ] || die "the moded stack needs an AMD compute GPU (supported device ids: $AMD_SUPPORTED_IDS); none found"
    sel=$(ask "   AMD GPUs for NAI endpoints (numbers from the list above)" "$def")
    i=0; for b in "${AMD_BDFS[@]}"; do i=$((i + 1))
      if [[ ",$sel," == *",$i,"* ]]; then amd_supported "$b" || warn "$b is not a tested compute GPU"; AMD_TARGETS="${AMD_TARGETS:+$AMD_TARGETS }$b"
      else AMD_OTHERS="${AMD_OTHERS:+$AMD_OTHERS }$b"; fi
    done
    [ -n "$AMD_TARGETS" ] || die "no AMD GPU chosen"
    if [ -n "$AMD_OTHERS" ]; then
      echo "   Other AMD GPUs ($AMD_OTHERS) must stay away from ROCm and Kubernetes:"
      echo "     vfio   bind them to vfio-pci at boot (they stop driving displays; one reboot, asked first)  [tested]"
      echo "     filter keep them on amdgpu, hide them from Kubernetes with the patched device plugin only"
      AMD_OTHER_POLICY=$(ask "   vfio or filter" vfio); [[ $AMD_OTHER_POLICY =~ ^(vfio|filter)$ ]] || die "answer vfio or filter"
    fi
    ok "AMD for NAI: $AMD_TARGETS${AMD_OTHERS:+; isolated ($AMD_OTHER_POLICY): $AMD_OTHERS}"
  fi
  save AMD_TARGETS "$AMD_TARGETS"; save AMD_OTHERS "$AMD_OTHERS"; save AMD_OTHER_POLICY "$AMD_OTHER_POLICY"

  echo; echo "${c_b}Storage${c_0}"
  local base need; base=$(largest_fs); base=${base%/}; need=600; [ $STACK = moded ] && need=900
  echo "   Installation storage: bundles and their unpacked copies, the local image registry, build space and the"
  echo "   local volumes for NKP platform apps and NAI databases. Wiped by --uninstall."
  ask_dir INSTALL_DIR "   Installation folder" "$base/nai-nkp" "$need"
  echo "   Model storage: NFS share for NAI model files (ReadWriteMany). --uninstall asks separately before deleting it."
  ask_dir MODEL_DIR "   Model folder" "$base/nai-models" 200
  [ "$INSTALL_DIR" != "$MODEL_DIR" ] && [[ $MODEL_DIR != "$INSTALL_DIR"/* ]] || die "keep the model folder outside the installation folder"
  [ "$(free_gb /var/lib)" -ge 200 ] || warn "only $(free_gb /var/lib) GB free for /var/lib (container images of the cluster need ~200 GB)"

  echo; echo "${c_b}Network${c_0}"
  HOST_IP=$(ask "   This host's IP (cluster endpoint, registry, NFS)" "$(host_ip)"); valid_ip "$HOST_IP" || die "not an IPv4 address"
  HOST_IFACE=$(ip -4 -o addr show | awk -v ip="$HOST_IP" '$4 ~ "^"ip"/" {print $2; exit}'); [ -n "$HOST_IFACE" ] || die "$HOST_IP is not on this host"
  local pfx; pfx=$(ip -4 -o addr show dev "$HOST_IFACE" | awk -v ip="$HOST_IP" '$4 ~ "^"ip"/" {print $4; exit}')
  echo "   MetalLB hands out service IPs on $pfx: the Kommander dashboard and the NAI gateway need one each."
  local r first last n
  while :; do
    r=$(ask "   Free address range for MetalLB (first-last, at least 2)"); first=${r%-*}; last=${r#*-}
    n=$(python3 -c "import ipaddress as a,sys;f,l,net=a.ip_address(sys.argv[1]),a.ip_address(sys.argv[2]),a.ip_network(sys.argv[3],strict=False);print(int(l)-int(f)+1 if f in net and l in net and l>=f else 0)" "$first" "$last" "$pfx" 2>/dev/null || echo 0)
    [ "$n" -ge 2 ] && break; echo "   give two addresses in $pfx, e.g. A.B.C.240-A.B.C.244" >/dev/tty
  done
  local used; used=$(python3 -c "import ipaddress as a,sys;f=int(a.ip_address(sys.argv[1]));print(' '.join(str(a.ip_address(f+i)) for i in range(int(sys.argv[2]))))" "$first" "$n" \
    | tr ' ' '\n' | while read -r ip; do ping -c1 -W1 "$ip" >/dev/null 2>&1 && echo -n "$ip "; done || true)
  [ -z "$used" ] && ok "MetalLB range $first-$last ($n addresses, none answering ping)" || warn "these answer ping and may be in use: $used"
  METALLB_RANGE="$first-$last"
  CLUSTER_NAME=$(ask "   Cluster name" nkp-nai); [[ $CLUSTER_NAME =~ ^[a-z0-9-]+$ ]] || die "lowercase letters, digits and '-' only"
  for v in HOST_IP HOST_IFACE METALLB_RANGE CLUSTER_NAME; do save $v "${!v}"; done
  save NAI_DNS "nai.$CLUSTER_NAME.lab"

  REBOOT_OK=no; local b vneed=no
  for b in $AMD_OTHERS; do [ "$AMD_OTHER_POLICY" = vfio ] && [ "$(drv "$b")" != vfio-pci ] && vneed=yes; done
  if { [ "$NV_COUNT" -gt 0 ] && ! nvidia-smi -L >/dev/null 2>&1; } || [ $vneed = yes ]; then
    echo; echo "${c_b}Reboot${c_0}: $([ $vneed = yes ] && echo "isolating $AMD_OTHERS with vfio-pci" || echo "loading the newly installed NVIDIA driver") may need one reboot."
    yesno "   May the setup reboot this host by itself when that point comes (it then continues on its own)" y && REBOOT_OK=yes
  fi
  save REBOOT_OK "$REBOOT_OK"

  echo; echo "${c_b}Summary${c_0}"
  echo "   Stack $STACK: NKP $NKP_VERSION (single node '$CLUSTER_NAME' on $HOST_IP, SSH user $INSTALL_USER) + NAI $NAI_VERSION"
  echo "   GPUs: NVIDIA ${NV_COUNT}$([ $STACK = moded ] && echo ", AMD $AMD_TARGETS${AMD_OTHERS:+ (isolate $AMD_OTHERS via $AMD_OTHER_POLICY)}")"
  echo "   Installation: $INSTALL_DIR    Models (NFS): $MODEL_DIR    MetalLB: $METALLB_RANGE"
  echo "   Host changes are recorded for --uninstall. Expect 2-4 h (downloads, image pushes, NKP, Kommander, NAI)."
  yesno "Start the installation with these settings" y || { rm -f "$CONF"; echo "Nothing changed. Run again to answer anew."; exit 0; }
}

# ---------------------------------------------------------------- 2. host
set_paths() {
  DL=$INSTALL_DIR/downloads; NKP_X=$INSTALL_DIR/nkp; NAI_OCI=$INSTALL_DIR/nai-oci; CHARTS=$INSTALL_DIR/charts
  WORK=$INSTALL_DIR/work; CL=$WORK/cluster; VALUES=$WORK/values; BUILD=$WORK/build
  REG=${HOST_IP:-127.0.0.1}:$REG_PORT; KCFG=$CL/${CLUSTER_NAME:-nkp}.conf
  PODMAN_BUILD=(podman --root "$INSTALL_DIR/podman-build/storage" --runroot /run/nai-nkp-podman)   # big builds off the root disk
  UHOME=$(user_home "${INSTALL_USER:-root}")
  export PATH="/usr/local/bin:$PATH"
}
nkp_dir() { { ls -d "$NKP_X"/nkp-v*/ 2>/dev/null || true; } | sort -V | tail -1 | sed 's:/$::'; }   # empty (not an error) before the bundle is unpacked

download_all() {   # right after the questions: everything on disk before the host is changed
  mkdir -p "$DL"; rec "DATADIR $INSTALL_DIR"
  local need=0 v b f
  for v in NKP_SRC NAI_TAR_SRC NAI_CHARTS_SRC; do b=${v}_BYTES; [[ ${!v} =~ ^https?:// ]] && need=$((need + ${!b:-0})); done
  [ $need = 0 ] || [ "$(free_gb "$DL")" -gt $((need / 1000000000 + 5)) ] || die "not enough space in $DL for the downloads ($(human $need))"
  for v in NKP_SRC NAI_TAR_SRC NAI_CHARTS_SRC; do
    [[ ${!v} =~ ^https?:// ]] || { printf -v "${v%_SRC}_FILE" '%s' "${!v}"; save "${v%_SRC}_FILE" "${!v}"; continue; }
    f=$DL/$(basename "${!v%%\?*}"); b=${v}_BYTES
    if [ ! -s "$f" ]; then echo "  downloading $(basename "$f") ($(human "${!b:-0}"))" | tee -a "$TLOG"; download "${!v}" "$f" || die "download failed; run again to resume (a fresh link may be needed)"; fi
    ok "$(basename "$f")"; printf -v "${v%_SRC}_FILE" '%s' "$f"; save "${v%_SRC}_FILE" "$f"
  done
}

check() {
  log "host check"
  . /etc/os-release; echo "  OS: $PRETTY_NAME, kernel $(uname -r)"
  [[ $VERSION_ID =~ ^(22.04|24.04|26.04)$ ]] || die "$PRETTY_NAME: NKP 2.18 needs Ubuntu 22.04/24.04 (26.04 with this script's workarounds)"
  gpu_report
  [ "$(nproc --all)" -ge 32 ] || warn "$(nproc --all) CPU threads: NKP platform + NAI need about 32"
  [ "$(free -g | awk '/Mem:/{print $2}')" -ge 128 ] || warn "less than 128 GB memory: NKP platform + NAI need about 96 GB before endpoints"
  [ -n "${INSTALL_DIR:-}" ] && ok "installation folder $INSTALL_DIR: $(free_gb "$INSTALL_DIR") GB free; models $MODEL_DIR: $(free_gb "$MODEL_DIR") GB free"
  return 0
}

host_packages() {
  # prerequisites konvoy installs itself from Ubuntu 22.04/24.04 repos: pre-installed so it finds them present on 26.04
  apt_install podman skopeo nfs-kernel-server chrony nfs-common rpcbind keyutils python3-cryptography python3-pip \
    python3-wheel ipvsadm lvm2 open-iscsi xfsprogs lsscsi wget curl ca-certificates pciutils patch
  ok "host packages installed ($(grep -c '^PKG ' "$MANIFEST") recorded for uninstall)"
}

gpu_drivers() {
  local why=() b f
  if [ "${NV_COUNT:-0}" -gt 0 ] && ! nvidia-smi -L >/dev/null 2>&1; then
    apt_install ubuntu-drivers-common
    local pkgs; pkgs=$(ubuntu-drivers list --gpgpu 2>/dev/null | grep -oE '^nvidia-driver-[0-9]+(-server)?-open' | sort -V | tail -1)
    [ -n "$pkgs" ] || pkgs=$(ubuntu-drivers list --gpgpu 2>/dev/null | grep -oE '^nvidia-driver-[0-9]+(-server)?' | sort -V | tail -1)
    [ -n "$pkgs" ] || die "ubuntu-drivers found no NVIDIA driver for this GPU (install one, then run again)"
    local mod; mod=$(ubuntu-drivers list --gpgpu 2>/dev/null | grep -F "$pkgs," | grep -oE 'linux-modules-nvidia-[^ )]+' | head -1)
    log "installing NVIDIA driver $pkgs ${mod:+($mod)}"; apt_install "$pkgs" ${mod:+"$mod"}
    modprobe nvidia 2>/dev/null || true
    nvidia-smi -L >/dev/null 2>&1 && ok "NVIDIA driver loaded: $(nvidia-smi --query-gpu=driver_version --format=csv,noheader | head -1)" || why+=("load the NVIDIA driver")
  fi
  if [ "$STACK" = moded ]; then
    apt_install rocminfo rocm-smi amd-smi libamdhip64-7 hip-utils 2>/dev/null || warn "ROCm tools not in this Ubuntu release's archive (host checks only; Kubernetes is unaffected)"
    for g in render video; do id -nG "$INSTALL_USER" | grep -qw $g || { usermod -aG $g "$INSTALL_USER"; rec "GROUP $INSTALL_USER $g"; }; done
    if [ "$AMD_OTHER_POLICY" = vfio ] && [ -n "$AMD_OTHERS" ]; then
      local ids="" all=true
      for b in $AMD_OTHERS; do for f in $(slot_functions "$b"); do ids="${ids:+$ids,}$(pci_ids "$f")"; [ "$(drv "$f")" = vfio-pci ] || all=false; done; done
      ids=$(echo "$ids" | tr ',' '\n' | awk '!s[$0]++' | paste -sd,)
      if ! $all; then
        [ -n "$(ls /sys/kernel/iommu_groups 2>/dev/null)" ] || die "IOMMU is off: enable it in the BIOS (AMD-Vi/VT-d) to isolate $AMD_OTHERS, or re-run with 'filter'"
        if [ ! -f /etc/modprobe.d/90-nai-nkp-vfio.conf ]; then
          printf '# nai-on-nkp: non-compute AMD GPU(s) %s kept away from amdgpu/ROCm/Kubernetes\noptions vfio-pci ids=%s\nsoftdep amdgpu pre: vfio-pci\nsoftdep snd_hda_intel pre: vfio-pci\n' \
            "$AMD_OTHERS" "$ids" > /etc/modprobe.d/90-nai-nkp-vfio.conf
          printf 'vfio\nvfio_iommu_type1\nvfio_pci\n' > /etc/modules-load.d/90-nai-nkp-vfio.conf
          rec "FILE /etc/modprobe.d/90-nai-nkp-vfio.conf"; rec "FILE /etc/modules-load.d/90-nai-nkp-vfio.conf"; rec "INITRAMFS"
          update-initramfs -u -k "$(uname -r)" >/dev/null
          cat /proc/sys/kernel/random/boot_id > "$DONE/reboot-vfio"
        elif [ "$(cat "$DONE/reboot-vfio" 2>/dev/null)" != "$(cat /proc/sys/kernel/random/boot_id)" ]; then
          die "$AMD_OTHERS still not on vfio-pci after the reboot (lspci -nnk -s ${AMD_OTHERS%% *}); not rebooting again"
        fi
        why+=("isolate $AMD_OTHERS with vfio-pci")
      fi
    fi
  fi
  if [ ${#why[@]} -gt 0 ]; then local msg; msg=$(printf '%s; ' "${why[@]}"); reboot_ask "${msg%; }"; fi
  return 0
}

os_prep() {
  local f=/etc/sudoers.d/90-nai-nkp-$INSTALL_USER
  if ! sudo -u "$INSTALL_USER" sudo -n true 2>/dev/null; then
    echo "$INSTALL_USER ALL=(ALL) NOPASSWD:ALL" > "$f"; chmod 440 "$f"; visudo -cf "$f" >/dev/null || { rm -f "$f"; die "sudoers check failed"; }; rec "FILE $f"
  fi
  if swapon --noheadings | grep -q .; then
    backup_file /etc/fstab; swapoff -a; sed -i -E 's|^([^#].*[[:space:]]swap[[:space:]].*)$|# disabled by nai-on-nkp: \1|' /etc/fstab; rec "SWAP"
  fi
  local s=$UHOME/.ssh k=$UHOME/.ssh/nkp_ed25519
  install -d -m 700 -o "$INSTALL_USER" -g "$(id -gn "$INSTALL_USER")" "$s"
  if [ ! -f "$k" ]; then sudo -u "$INSTALL_USER" ssh-keygen -q -t ed25519 -N "" -C nai-on-nkp -f "$k"; rec "FILE $k"; rec "FILE $k.pub"; fi
  grep -qF "$(cat "$k.pub")" "$s/authorized_keys" 2>/dev/null || { cat "$k.pub" >> "$s/authorized_keys"; rec "AUTHKEY $s/authorized_keys nai-on-nkp"; }
  chown "$INSTALL_USER" "$s/authorized_keys"; chmod 600 "$s/authorized_keys"
  sudo -u "$INSTALL_USER" ssh -i "$k" -o StrictHostKeyChecking=accept-new -o BatchMode=yes "$INSTALL_USER@$HOST_IP" sudo -n true \
    || die "NKP's SSH login $INSTALL_USER@$HOST_IP with the key failed (sshd running? key auth allowed?)"
  if ! grep -qs '^pids_limit *= *0' /etc/containers/containers.conf; then
    backup_file /etc/containers/containers.conf; mkdir -p /etc/containers
    printf '[containers]\n# nai-on-nkp: the NKP bootstrap (kind in podman) needs more than the default 2048 processes\npids_limit = 0\n' > /etc/containers/containers.conf
  fi
  printf 'fs.inotify.max_user_instances = 8192\nfs.inotify.max_user_watches = 1048576\n' > /etc/sysctl.d/90-nai-nkp.conf; rec "FILE /etc/sysctl.d/90-nai-nkp.conf"
  sysctl -q --system
  if [ "$(systemctl show -p LoadState --value cloud-init.service)" != loaded ]; then   # 26.04 split cloud-init.service; NKP's playbook expects it
    printf '# nai-on-nkp: compatibility shim for NKP image-builder on Ubuntu 26.04\n[Unit]\nDescription=Compat shim for cloud-init.service\nAfter=cloud-init-network.service\n[Service]\nType=oneshot\nExecStart=/bin/true\nRemainAfterExit=yes\n[Install]\nWantedBy=cloud-init.target\n' \
      > /etc/systemd/system/cloud-init.service; rec "FILE /etc/systemd/system/cloud-init.service"; systemctl daemon-reload
  fi
  systemctl enable --now chrony >/dev/null 2>&1 || true
  ok "OS prepared for NKP (sudo, swap off, SSH key, podman and inotify limits)"
}

tools() {
  local nd; nd=$(nkp_dir)
  if [ -z "$nd" ] || [ ! -x "$nd/cli/nkp" ]; then
    mkdir -p "$NKP_X"; echo "  unpacking the NKP bundle (10-20 min)" | tee -a "$TLOG"; tar -xzf "$NKP_FILE" -C "$NKP_X"; nd=$(nkp_dir)
  fi
  [ -x "$nd/cli/nkp" ] || die "the NKP bundle has no cli/nkp"
  for f in nkp kubectl helm; do [ -e /usr/local/bin/$f ] || rec "FILE /usr/local/bin/$f"; done
  install -m 755 "$nd/cli/nkp" /usr/local/bin/nkp; install -m 755 "$nd/kubectl" /usr/local/bin/kubectl
  if ! helm version >/dev/null 2>&1; then
    mkdir -p "$WORK"; download "https://get.helm.sh/helm-$HELM_VERSION-linux-amd64.tar.gz" "$WORK/helm.tgz" || die "cannot download helm"
    tar -xzf "$WORK/helm.tgz" -C "$WORK"; install -m 755 "$WORK/linux-amd64/helm" /usr/local/bin/helm
  fi
  mkdir -p "$NAI_OCI" "$CHARTS"
  [ -s "$NAI_OCI/index.json" ] || { echo "  unpacking the NAI image bundle" | tee -a "$TLOG"; tar -xf "$NAI_TAR_FILE" -C "$NAI_OCI"; }
  [ -s "$NAI_OCI/index.json" ] || die "the NAI image bundle is not an OCI archive (index.json missing)"
  if [ ! -d "$CHARTS/nai-core" ]; then
    mkdir -p "$CHARTS/tgz"; tar -xf "$NAI_CHARTS_FILE" -C "$CHARTS/tgz"; find "$CHARTS/tgz" -name '*.tgz' -exec tar -xzf {} -C "$CHARTS" \;
  fi
  local c; for c in gateway-crds-helm gateway-helm kserve-crd kserve-llmisvc-crd kserve-resources kserve-llmisvc-resources lws opentelemetry-operator nai-operators nai-core; do
    [ -d "$CHARTS/$c" ] || die "chart $c missing from the NAI chart bundle"; done
  ok "nkp $(nkp version 2>/dev/null | awk '/nkp:/{print $2}'), kubectl, helm $(helm version --short); NAI bundle $(python3 -c "import json;print(len(json.load(open('$NAI_OCI/index.json'))['manifests']))") images, charts complete"
}

# ---------------------------------------------------------------- 3. NKP
REG_UNIT=/etc/systemd/system/nkp-registry.service
registry() {   # air-gap registry for NKP and NAI images; host network (no NAT rules a firewall reload could wipe)
  # Runs as its own systemd service. Started with `podman run -d` from this script it lived in the
  # install job's cgroup, and systemd killed it whenever the job exited (e.g. on a failed stage),
  # leaving the cluster unable to pull images. Idempotent: also replaces such an old container.
  if [ ! -f "$REG_UNIT" ] || ! curl -fsS -m 5 "http://$REG/v2/" >/dev/null 2>&1; then
    mkdir -p "$INSTALL_DIR/registry"
    podman image exists docker.io/library/registry:2 || retry podman pull -q docker.io/library/registry:2 >/dev/null || die "cannot pull docker.io/library/registry:2 (check DNS / internet access to Docker Hub)"
    systemctl stop nkp-registry.service >/dev/null 2>&1 || true
    podman rm -f nkp-registry >/dev/null 2>&1 || true
    port_free "$REG_PORT" || die "port $REG_PORT is in use by something else (set REG_PORT=...)"
    [ -f "$REG_UNIT" ] || rec "FILE $REG_UNIT"
    cat > "$REG_UNIT" <<EOF
[Unit]
Description=Air-gap image registry for NKP and NAI (nai-on-nkp)
Wants=network-online.target
After=network-online.target

[Service]
ExecStartPre=-$(command -v podman) rm -f nkp-registry
ExecStart=$(command -v podman) run --rm --name nkp-registry --network host -e REGISTRY_HTTP_ADDR=0.0.0.0:$REG_PORT -v $INSTALL_DIR/registry:/var/lib/registry:Z docker.io/library/registry:2
ExecStop=$(command -v podman) stop -t 10 nkp-registry
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl is-enabled -q nkp-registry.service 2>/dev/null || rec "SERVICE nkp-registry.service"
    systemctl enable --now nkp-registry.service >/dev/null 2>&1 || die "cannot start nkp-registry.service (journalctl -u nkp-registry)"
    grep -qx "CONTAINER nkp-registry" "$MANIFEST" || rec "CONTAINER nkp-registry"
    wait_for "registry answering" 60 2 "curl -fsS -m 3 http://$REG/v2/ >/dev/null" || true
  fi
  curl -fsS -m 5 "http://$REG/v2/" >/dev/null || die "registry $REG not reachable (journalctl -u nkp-registry)"
  ok "registry http://$REG ($INSTALL_DIR/registry, nkp-registry.service)"
}

nkp_images() {
  local nd A f kimg bundles; nd=$(nkp_dir); A=$nd/image-artifacts
  bundles=$(ls "$nd"/container-images/{konvoy-image-bundle,kommander-image-bundle}-v*.tar "$nd"/container-images/nutanix-product-catalog-v*-airgapped.tar 2>/dev/null | paste -sd,)
  [ -n "$bundles" ] || die "NKP container image bundles not found in $nd/container-images"
  echo "  pushing NKP images to $REG (20-40 min)" | tee -a "$TLOG"
  nkp push bundle --bundle "$bundles" --to-registry "http://$REG" --to-registry-insecure-skip-tls-verify --image-push-concurrency 4 >> "$LOG" 2>&1 \
    || die "nkp push bundle failed (see $LOG)"
  . /etc/os-release
  if [ "$VERSION_ID" = 26.04 ]; then   # NKP 2.18 ships OS artifacts for 22.04/24.04 only: build 24.04's, alias them as 26.04
    ls "$A"/*_ubuntu_24.04_x86_64.tar.gz >/dev/null 2>&1 || { echo "  building the Ubuntu 24.04 OS package bundle (internet)" | tee -a "$TLOG"
      nkp create package-bundle ubuntu-24.04 --artifacts-directory "$A" >> "$LOG" 2>&1 || die "nkp create package-bundle failed"; }
    for f in "$A"/*24.04*; do [ -e "${f//24.04/26.04}" ] || ln -sf "$(basename "$f")" "${f//24.04/26.04}"; done
  fi
  kimg=$(ls "$A"/images/kubernetes-images-*.tar | head -1)
  ( cd "$nd" && rm -rf .nkp-image-builder-* )
  echo "  uploading containerd and Kubernetes packages to the host" | tee -a "$TLOG"
  nkp upload image-artifacts --artifacts-directory "$A" --ssh-host "$HOST_IP" --ssh-username "$INSTALL_USER" \
    --ssh-private-key-file "$UHOME/.ssh/nkp_ed25519" --bundle "$kimg" >> "$LOG" 2>&1 || die "nkp upload image-artifacts failed (see $LOG)"
  rec "NKPHOST"   # from here konvoy changes the host (apt offline repo, containerd, kubelet...): full teardown on uninstall
  local nrepo; nrepo=$(curl -fsS "http://$REG/v2/_catalog?n=1000" 2>/dev/null | python3 -c 'import json,sys;print(len(json.load(sys.stdin)["repositories"]))' 2>/dev/null) || nrepo="?"   # registry:2 rejects n > 1000
  ok "NKP images ($nrepo repositories) and OS artifacts in place"
}

host_storage() {
  local i s d fst=""
  for i in $(seq -w 1 "$LOCAL_PV_COUNT"); do s=$INSTALL_DIR/local-pv/vol$i; d=/mnt/disks/vol$i; mkdir -p "$s" "$d"; fst+="$s $d none bind 0 0"$'\n'; done
  for i in $(seq 1 "$NAI_PV_COUNT"); do s=$INSTALL_DIR/nai-local/vol$i; d=/mnt/nai-disks/vol$i; mkdir -p "$s" "$d"; fst+="$s $d none bind 0 0"$'\n'; done
  rec "DIR /mnt/disks"; rec "DIR /mnt/nai-disks"
  block_set /etc/fstab volumes "${fst%$'\n'}"; systemctl daemon-reload; mount -a
  mkdir -p "$MODEL_DIR"; chmod 0777 "$MODEL_DIR"; rec "MODELDIR $MODEL_DIR"
  local o="rw,sync,no_subtree_check,no_root_squash"
  block_set /etc/exports models "$MODEL_DIR $HOST_IP/32($o) 127.0.0.1($o) $POD_CIDR($o)"
  mkdir -p /etc/systemd/system/nfs-server.service.d
  printf '[Unit]\nRequiresMountsFor=%s\n' "$MODEL_DIR" > /etc/systemd/system/nfs-server.service.d/90-nai-nkp.conf; rec "FILE /etc/systemd/system/nfs-server.service.d/90-nai-nkp.conf"
  systemctl daemon-reload; systemctl enable --now nfs-server >/dev/null 2>&1 || systemctl enable --now nfs-kernel-server >/dev/null 2>&1; exportfs -ra
  ok "$LOCAL_PV_COUNT platform + $NAI_PV_COUNT NAI local volumes; NFS export $MODEL_DIR"
}

write_inventory() {
  mkdir -p "$CL"; local n
  for n in control-plane md-0; do cat <<EOF
---
apiVersion: infrastructure.cluster.konvoy.d2iq.io/v1alpha1
kind: PreprovisionedInventory
metadata:
  name: ${CLUSTER_NAME}-$n
  namespace: default
  labels: {cluster.x-k8s.io/cluster-name: ${CLUSTER_NAME}, clusterctl.cluster.x-k8s.io/move: ""}
spec:
  hosts: $([ $n = control-plane ] && echo "[{address: $HOST_IP}]" || echo "[]")
  sshConfig: {port: 22, user: ${INSTALL_USER}, privateKeyRef: {name: ${CLUSTER_NAME}-ssh-key, namespace: default}}
EOF
  done > "$CL/inventory.yaml"   # NKP expects an md-0 inventory even with 0 workers
}

cluster() {
  local nd boot; nd=$(nkp_dir); boot=$(ls "$nd"/konvoy-bootstrap-image-v*.tar | head -1); write_inventory
  if [ ! -s "$KCFG" ] || ! kc get nodes >/dev/null 2>&1; then
    rec "NKPCLUSTER $CLUSTER_NAME"
    # single node: make the control plane schedulable as soon as the API answers. Every command may fail
    # (API not up yet, taint already gone) and must not end the loop under set -e: the CAPI operator job
    # inside the new cluster stays Pending, and nkp create cluster times out after 20 min, until it's gone.
    ( set +e; for i in $(seq 1 720); do
        [ -f /etc/kubernetes/admin.conf ] && kubectl --kubeconfig /etc/kubernetes/admin.conf taint nodes --all node-role.kubernetes.io/control-plane:NoSchedule- >/dev/null 2>&1
        pgrep -f "nkp create cluster preprovisioned" >/dev/null || break; sleep 10; done; true ) &
    local w=$! rc=0
    log "creating NKP cluster $CLUSTER_NAME (30-60 min; detail in $LOG)"
    ( cd "$CL" && nkp create cluster preprovisioned --cluster-name "$CLUSTER_NAME" --control-plane-endpoint-host "$HOST_IP" \
        --control-plane-replicas 1 --worker-replicas 0 --pre-provisioned-inventory-file inventory.yaml \
        --ssh-private-key-file "$UHOME/.ssh/nkp_ed25519" --ssh-username "$INSTALL_USER" --registry-mirror-url "http://$REG" \
        --bootstrap-cluster-image "$boot" --self-managed --timeout 120m ) >> "$LOG" 2>&1 || rc=$?
    kill $w 2>/dev/null || true
    [ -s "$CL/$CLUSTER_NAME.conf" ] || nkp get kubeconfig -c "$CLUSTER_NAME" > "$KCFG" 2>>"$LOG" || true
    [ $rc = 0 ] || warn "nkp create cluster ended with $rc"
  fi
  # Self-managed: the CAPI objects must live in the new cluster before the bootstrap cluster is deleted.
  # Checked on every run (not only when the cluster was just created), so a re-run after a failed move
  # finishes it instead of deleting the bootstrap cluster that still holds them.
  if ! kc get clusters.cluster.x-k8s.io -A --no-headers 2>/dev/null | grep -q "$CLUSTER_NAME"; then
    warn "completing the self-managed move (CAPI controllers can be slow on one node)"
    kc get nodes >/dev/null 2>&1 || die "the cluster API is not reachable (see $LOG)"
    kc taint nodes --all node-role.kubernetes.io/control-plane:NoSchedule- >/dev/null 2>&1 || true
    kc delete namespace capi-stack-operator-installer --ignore-not-found --wait=true >> "$LOG" 2>&1 || true   # leftovers of a timed-out attempt
    nkp create capi-components --kubeconfig "$KCFG" >> "$LOG" 2>&1 || die "nkp create capi-components failed (see $LOG)"
    [ -s "$CL/$CLUSTER_NAME-bootstrap.conf" ] || die "bootstrap kubeconfig missing: cannot move the CAPI objects"
    nkp move capi-resources --from-kubeconfig "$CL/$CLUSTER_NAME-bootstrap.conf" --to-kubeconfig "$KCFG" >> "$LOG" 2>&1 \
      || nkp move capi-resources --to-kubeconfig "$KCFG" >> "$LOG" 2>&1 || die "nkp move capi-resources failed (see $LOG)"
    kc get clusters.cluster.x-k8s.io -A --no-headers 2>/dev/null | grep -q "$CLUSTER_NAME" || die "CAPI cluster object not in the new cluster after the move"
  fi
  nkp delete bootstrap --kubeconfig "$CL/$CLUSTER_NAME-bootstrap.conf" >> "$LOG" 2>&1 || nkp delete bootstrap >> "$LOG" 2>&1 || true
  chmod 600 "$KCFG"
  local uk=$UHOME/.kube/config; mkdir -p "$UHOME/.kube"; [ -e "$uk" ] && backup_file "$uk" || rec "FILE $uk"
  cp "$KCFG" "$uk"; chown -R "$INSTALL_USER" "$UHOME/.kube"; chmod 600 "$uk"
  kc taint nodes --all node-role.kubernetes.io/control-plane:NoSchedule- >/dev/null 2>&1 || true
  local F=/var/lib/kubelet/config.yaml   # one node runs every platform pod: 110 is too few (Kommander install hangs)
  if ! grep -q "^maxPods: $KUBELET_MAX_PODS" $F; then
    if grep -q '^maxPods:' $F; then sed -i "s/^maxPods:.*/maxPods: $KUBELET_MAX_PODS/" $F; else echo "maxPods: $KUBELET_MAX_PODS" >> $F; fi
    systemctl restart kubelet; sleep 20
  fi
  wait_for "node Ready" 600 10 "kubectl --kubeconfig $KCFG get nodes --no-headers | grep -q ' Ready '" || die "node not Ready"
  kc get clusters -A --no-headers 2>/dev/null | grep -q "$CLUSTER_NAME" || warn "CAPI cluster object not found (cluster still works; NKP lifecycle commands may not)"
  ok "NKP cluster $CLUSTER_NAME: $(kc get nodes --no-headers | awk '{print $1, $2, $5}'), maxPods $KUBELET_MAX_PODS"
}

kommander() {
  wait_for "MetalLB ready" 900 10 "kubectl --kubeconfig $KCFG get crd ipaddresspools.metallb.io" || die "MetalLB CRDs missing"
  kc apply -f - >/dev/null <<EOF
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata: {name: nai-nkp-pool, namespace: metallb-system}
spec: {addresses: [${METALLB_RANGE}]}
---
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata: {name: nai-nkp-l2, namespace: metallb-system}
spec: {ipAddressPools: [nai-nkp-pool], interfaces: [${HOST_IFACE}]}
EOF
  local nv=false; [ "${NV_COUNT:-0}" -gt 0 ] && nv=true
  cat > "$CL/kommander.yaml" <<EOF
apiVersion: config.kommander.mesosphere.io/v1alpha1
kind: Installation
# single bare-metal node without object storage: rook-ceph, velero, logging and insights are off
apps:
  cloudnative-pg: {enabled: true}
  dex: {enabled: true}
  dex-k8s-authenticator: {enabled: true}
  external-secrets: {enabled: true}
  gatekeeper: {enabled: true}
  git-operator: {enabled: true}
  kommander: {enabled: true}
  kommander-ui: {enabled: true}
  kube-prometheus-stack: {enabled: true}
  kubefed: {enabled: true}
  kubernetes-dashboard: {enabled: true}
  kubetunnel: {enabled: true}
  prometheus-adapter: {enabled: true}
  reloader: {enabled: true}
  traefik: {enabled: true}
  traefik-forward-auth-mgmt: {enabled: true}
  nvidia-gpu-operator:
    enabled: ${nv}
    # host driver; CDI as default so containerd's default runtime stays runc (AMD/CPU pods unaffected)
    values: |
      driver:
        enabled: false
      toolkit:
        enabled: true
      cdi:
        enabled: true
        default: true
ageEncryptionSecretName: sops-age
clusterHostname: ""
airgapped:
  enabled: true
EOF
  local A; A=$(ls "$(nkp_dir)"/application-repositories/kommander-applications-v*.tar.gz | head -1)
  log "installing Kommander (30-90 min)"
  nkp install kommander --installer-config "$CL/kommander.yaml" --kommander-applications-repository "$A" --kubeconfig "$KCFG" \
    --wait-timeout 2h >> "$LOG" 2>&1 || die "Kommander install failed (see $LOG; kubectl get helmreleases -A)"
  # Grafana's datasource sidecar reload gets 401 (auth.proxy): reload once from inside the pod
  wait_for "Grafana running" 900 15 "kubectl --kubeconfig $KCFG -n kommander get deploy kube-prometheus-stack-grafana -o jsonpath='{.status.readyReplicas}' | grep -q 1" \
    && kc -n kommander exec deploy/kube-prometheus-stack-grafana -c grafana -- wget -qO- --post-data='' --header='X-Forwarded-User: admin' \
       http://localhost:3000/api/admin/provisioning/datasources/reload >/dev/null 2>&1 || warn "Grafana datasource reload skipped"
  KOMMANDER_IP=$(kc -n kommander get svc kommander-traefik -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null); save KOMMANDER_IP "$KOMMANDER_IP"
  if [ "$nv" = true ]; then
    wait_for "nvidia.com/gpu allocatable" 1800 20 "[ \"\$(kubectl --kubeconfig $KCFG get node -o jsonpath='{.items[0].status.allocatable.nvidia\.com/gpu}')\" -ge 1 ]" \
      || warn "NVIDIA GPU not allocatable yet (kubectl -n kommander get pods | grep nvidia)"
  fi
  ok "Kommander dashboard https://$KOMMANDER_IP/dkp/kommander/dashboard (login: nkp get dashboard)"
}

# ---------------------------------------------------------------- 4. storage classes, images, AMD, NAI
cluster_storage() {
  kc -n kube-system get ds local-volume-provisioner -o json | python3 -c '
import json, sys
d = json.load(sys.stdin); d.pop("status", None)
sel = {"app": "nai-local-volume-provisioner"}
d["metadata"] = {"name": "nai-local-volume-provisioner", "namespace": "kube-system", "labels": sel}
d["spec"]["selector"] = {"matchLabels": sel}; t = d["spec"]["template"]; t["metadata"] = {"labels": sel}
for v in t["spec"]["volumes"]:
    if v["name"] == "provisioner-config": v["configMap"]["name"] = "nai-local-provisioner-config"
    if v["name"] == "disks": v["hostPath"]["path"] = "/mnt/nai-disks"
for m in t["spec"]["containers"][0]["volumeMounts"]:
    if m["name"] == "disks": m["mountPath"] = "/mnt/nai-disks"
json.dump(d, sys.stdout)' > "$CL/nai-lvp-ds.json" || die "NKP's local-volume-provisioner not found (kube-system)"
  cat > "$CL/nai-local.yaml" <<'EOF'
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata: {name: nai-local}
provisioner: kubernetes.io/no-provisioner
volumeBindingMode: WaitForFirstConsumer
reclaimPolicy: Delete
---
apiVersion: v1
kind: ConfigMap
metadata: {name: nai-local-provisioner-config, namespace: kube-system}
data:
  storageClassMap: |
    nai-local:
       hostDir: /mnt/nai-disks
       mountDir: /mnt/nai-disks
       blockCleanerCommand: ["/scripts/shred.sh", "2"]
       volumeMode: Filesystem
       accessMode: ReadWriteOnce
       namePattern: "*"
EOF
  kc apply -f "$CL/nai-local.yaml" -f "$CL/nai-lvp-ds.json" >/dev/null
  local t=$WORK/csi-driver-nfs-$CSI_NFS_VERSION.tgz c
  if [ ! -s "$t" ]; then mkdir -p "$WORK"
    # the chart's own URL (no helm repo / index needed), retried: this lab's internet access has short outages
    ( cd "$WORK" && retry hl pull "https://raw.githubusercontent.com/kubernetes-csi/csi-driver-nfs/master/charts/v$CSI_NFS_VERSION/csi-driver-nfs-$CSI_NFS_VERSION.tgz" ) \
      || die "cannot fetch csi-driver-nfs $CSI_NFS_VERSION (check internet access to raw.githubusercontent.com)"
  fi
  for c in $(hl template x "$t" -n kube-system | grep -oE 'image: *"?[^" ]+' | sed -E 's/image: *"?//' | sort -u); do mirror_image "$c" || die "mirror failed: $c"; done
  hinst csi-driver-nfs "$t" kube-system 10m --set externalSnapshotter.enabled=false
  kc apply -f - >/dev/null <<EOF
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata: {name: nai-nfs-storage}
provisioner: nfs.csi.k8s.io
parameters: {server: "${HOST_IP}", share: "${MODEL_DIR}"}
reclaimPolicy: Delete
volumeBindingMode: Immediate
allowVolumeExpansion: true
mountOptions: [nfsvers=4.1, hard]
EOF
  wait_for "nai-local volumes available" 300 10 "[ \$(kubectl --kubeconfig $KCFG get pv --no-headers 2>/dev/null | grep -c ' nai-local ') -ge $NAI_PV_COUNT ]" || die "nai-local volumes missing"
  ok "storage classes nai-local (RWO, $NAI_PV_COUNT volumes) and nai-nfs-storage (RWX on $HOST_IP:$MODEL_DIR)"
}

nai_images() {
  registry_ensure
  local n=0 f=0 i ref
  while read -r i ref; do n=$((n + 1)); reg_has "${ref#docker.io/}" && continue
    skopeo copy -q --dest-tls-verify=false "oci:$NAI_OCI:@$i" "docker://$REG/${ref#docker.io/}" || { f=$((f + 1)); warn "push failed: $ref"; }
  done < <(python3 -c 'import json,sys;[print(i, m["annotations"]["io.containerd.image.name"]) for i, m in enumerate(json.load(open(sys.argv[1]))["manifests"])]' "$NAI_OCI/index.json")
  [ $f = 0 ] || die "$f NAI image(s) failed to push"
  mirror_image docker.io/kserve/storage-initializer:v0.19.0 || warn "kserve/storage-initializer not mirrored (NAI model download jobs may need it)"
  ok "$n NAI images in $REG"
}

# --- moded stack
amd_operator() {
  local V=$AMD_OPERATOR_VERSION img
  if ! reg_has "charts/gpu-operator-charts:$V"; then
    mkdir -p "$BUILD"; ( cd "$BUILD" && rm -f gpu-operator-charts-*.tgz
      retry hl repo add --force-update rocm https://rocm.github.io/gpu-operator >/dev/null && retry hl pull rocm/gpu-operator-charts --version "$V" ) \
      || die "cannot fetch the AMD GPU Operator chart $V (check internet access to rocm.github.io)"
    hl push "$BUILD/gpu-operator-charts-$V.tgz" "oci://$REG/charts" --plain-http >/dev/null || die "chart push failed"
  fi
  for img in docker.io/rocm/gpu-operator:$V docker.io/rocm/k8s-device-plugin:latest docker.io/rocm/k8s-device-plugin:labeller-latest \
             docker.io/rocm/device-metrics-exporter:$V docker.io/rocm/gpu-operator-utils:$V docker.io/rocm/test-runner:$V \
             docker.io/library/busybox:1.36 quay.io/brancz/kube-rbac-proxy:v0.18.1; do mirror_image "$img" || die "mirror failed: $img"; done
  local filter=0 b; [ "$AMD_OTHER_POLICY" = filter ] && [ -n "$AMD_OTHERS" ] && filter=1
  if [ $filter = 1 ]; then   # stock plugin cannot exclude a device: build the PCI-filtered plugin and write the node's filter
    if ! reg_has rocm/k8s-device-plugin:pcifilter; then
      local B=$BUILD/amd-device-plugin src; rm -rf "$B"; mkdir -p "$B"; tar -xzf "$ASSETS/amd-device-plugin/k8s-device-plugin-src.tgz" -C "$B"
      src=$(ls -d "$B"/*/ | head -1); ( cd "$src" && patch -p1 < "$ASSETS/amd-device-plugin/amd-dp-pcifilter.patch" ) >> "$LOG" 2>&1 || die "device plugin patch did not apply"
      "${PODMAN_BUILD[@]}" build -q -t docker.io/rocm/k8s-device-plugin:pcifilter "$src" >> "$LOG" 2>&1 || die "device plugin build failed"
      "${PODMAN_BUILD[@]}" push -q --tls-verify=false docker.io/rocm/k8s-device-plugin:pcifilter "docker://$REG/rocm/k8s-device-plugin:pcifilter" >> "$LOG" 2>&1
    fi
    mkdir -p /var/lib/kubelet/device-plugins
    printf '# nai-on-nkp: AMD device plugin PCI filter\nallow=%s\ndeny=%s\n' "$(echo $AMD_TARGETS | tr ' ' ,)" "$(echo $AMD_OTHERS | tr ' ' ,)" \
      > /var/lib/kubelet/device-plugins/amd-gpu-pci-filter.conf
  fi
  local C=$WORK/amd-gpu-catalog R tag
  rm -rf "$C"; mkdir -p "$C"; cp -r "$ASSETS/amd-catalog/applications" "$C/"; R=$C/applications/amd-gpu-operator/1.5.1/release
  sed -i "s#__REGISTRY__#$REG#" "$R/amd-gpu-operator.yaml"; sed -i "s#__AMD_ECC_UMC_THRESHOLD__#$AMD_ECC_UMC_THRESHOLD#" "$R/amd-metrics-config.yaml"
  [ $filter = 1 ] || sed -i '/Lab-patched plugin/d; /allow=\/deny= PCI addresses/d; /devicePluginImage: docker.io\/rocm\/k8s-device-plugin:pcifilter/d; /devicePluginImagePullPolicy: Always/d' "$R/cm.yaml"
  ( cd "$C" && nkp validate catalog-repository --repo-dir . ) >> "$LOG" 2>&1 || die "AMD catalog validation failed (see $LOG)"
  tag=v1.0.$(date +%s)
  ( cd "$C" && rm -f ./*.tar && nkp create catalog-bundle --repo-dir . --collection-tag "$tag" ) >> "$LOG" 2>&1 || die "catalog bundle failed"
  nkp push bundle --bundle "$C/amd-gpu-catalog-$tag.tar" --to-registry "http://$REG" --to-registry-insecure-skip-tls-verify >> "$LOG" 2>&1 || die "catalog push failed"
  if kc -n kommander get ocirepository amd-gpu-catalog-collection >/dev/null 2>&1; then
    kc -n kommander patch ocirepository amd-gpu-catalog-collection --type merge -p "{\"spec\":{\"ref\":{\"tag\":\"$tag\"}}}" >/dev/null
  else nkp create catalog-collection --url "oci://$REG/amd-gpu-catalog/collection" --tag "$tag" --workspace kommander-workspace --insecure >> "$LOG" 2>&1 || die "catalog collection failed"; fi
  wait_for "AMD GPU Operator app in the catalog" 600 10 "kubectl --kubeconfig $KCFG -n kommander get app amd-gpu-operator-1.5.1" || die "AMD app not visible"
  kc -n kommander get appdeployment amd-gpu-operator >/dev/null 2>&1 || nkp create appdeployment amd-gpu-operator --app amd-gpu-operator-1.5.1 --workspace kommander-workspace >> "$LOG" 2>&1
  wait_for "AMD GPU Operator running" 1200 15 "[ \"\$(kubectl --kubeconfig $KCFG -n kommander get helmrelease amd-gpu-operator -o jsonpath='{.status.conditions[?(@.type==\"Ready\")].status}')\" = True ]" || die "AMD GPU Operator HelmRelease not ready"
  local want; want=$(echo $AMD_TARGETS | wc -w)
  wait_for "amd.com/gpu allocatable: $want" 900 15 "[ \"\$(kubectl --kubeconfig $KCFG get node -o jsonpath='{.items[0].status.allocatable.amd\.com/gpu}')\" = $want ]" \
    || die "amd.com/gpu is not $want (kubectl -n kommander get pods | grep amd)"
}

rocm_image() {   # ROCm vLLM wrapped for NAI (entrypoint contract, uid 65534 access, Triton flash-attention); built off the root disk
  reg_has "${ROCM_VLLM_IMAGE#docker.io/}:$ROCM_VLLM_TAG" && { ok "ROCm vLLM image already in $REG"; return; }
  mkdir -p "$INSTALL_DIR/podman-build"
  "${PODMAN_BUILD[@]}" image exists "$ROCM_VLLM_BASE" || { echo "  pulling $ROCM_VLLM_BASE (~75 GB, 30-90 min)" | tee -a "$TLOG"
    "${PODMAN_BUILD[@]}" pull -q "$ROCM_VLLM_BASE" >> "$LOG" 2>&1 || die "pull of the ROCm vLLM base image failed"; }
  "${PODMAN_BUILD[@]}" build -q --pull=never --build-arg "BASE=$ROCM_VLLM_BASE" -t "$ROCM_VLLM_IMAGE:$ROCM_VLLM_TAG" "$ASSETS/rocm-vllm" >> "$LOG" 2>&1 || die "ROCm wrapper build failed"
  # NAI runs the engine as uid 65534 on a read-only root: vllm must be executable and its python must import vllm.
  # No GPU here, so don't run `vllm --version`: vLLM >= 0.29 builds its full CLI config for that and fails to infer a device.
  "${PODMAN_BUILD[@]}" run --rm --user 65534 --read-only --entrypoint sh "$ROCM_VLLM_IMAGE:$ROCM_VLLM_TAG" -c \
    'v=$(command -v vllm) && test -x "$v" && py=$(sed -n "1s/^#!//p" "$v") && "$py" -c "import vllm; print(\"vllm\", vllm.__version__)"' \
    >> "$LOG" 2>&1 || die "ROCm vLLM image: vllm not runnable as uid 65534 (see $LOG)"
  echo "  pushing the ROCm vLLM image to $REG" | tee -a "$TLOG"
  "${PODMAN_BUILD[@]}" push -q --tls-verify=false "$ROCM_VLLM_IMAGE:$ROCM_VLLM_TAG" "docker://$REG/${ROCM_VLLM_IMAGE#docker.io/}:$ROCM_VLLM_TAG" >> "$LOG" 2>&1 || die "push failed"
  ok "ROCm vLLM image $ROCM_VLLM_IMAGE:$ROCM_VLLM_TAG"
}

patched_image() {   # name path-in-image patch-cmd new-tag asset-dir
  local name=$1 inpath=$2 pcmd=$3 tag=$4 B=$BUILD/$1 cid base=docker.io/nutanix/$1:v$NAI_VERSION
  reg_has "nutanix/$name:$tag" && return 0
  rm -rf "$B"; mkdir -p "$B"; cp "$ASSETS/$5"/* "$B/"
  "${PODMAN_BUILD[@]}" pull -q --tls-verify=false "$REG/nutanix/$name:v$NAI_VERSION" >> "$LOG" 2>&1 || die "cannot pull $name from $REG"
  "${PODMAN_BUILD[@]}" tag "$REG/nutanix/$name:v$NAI_VERSION" "$base"
  cid=$("${PODMAN_BUILD[@]}" create "$base"); "${PODMAN_BUILD[@]}" cp "$cid:$inpath" "$B/orig" >> "$LOG" 2>&1; "${PODMAN_BUILD[@]}" rm "$cid" >/dev/null
  ( cd "$B" && eval "$pcmd" ) >> "$LOG" 2>&1 || die "$name patch refused or failed (NAI build other than $TESTED_NAI?) - see $LOG"
  "${PODMAN_BUILD[@]}" build -q --pull=never --build-arg "BASE=$base" -t "docker.io/nutanix/$name:$tag" "$B" >> "$LOG" 2>&1 || die "$name build failed"
  "${PODMAN_BUILD[@]}" push -q --tls-verify=false "docker.io/nutanix/$name:$tag" "docker://$REG/nutanix/$name:$tag" >> "$LOG" 2>&1 || die "$name push failed"
}

nai_patches() {   # moded: chart (amd-gpu-passthrough platform + ROCm image), API validator, UI GPU selection
  [ "$NAI_VERSION" = "$TESTED_NAI" ] || die "the NAI API/UI patches are specific to NAI $TESTED_NAI (this bundle is $NAI_VERSION)"
  grep -q supportedVLLMROCmImage "$CHARTS/nai-core/values.yaml" || python3 "$ASSETS/nai-chart-patch/patch-nai-amdgpu.py" "$CHARTS/nai-core" >> "$LOG" 2>&1 || die "nai-core chart patch failed"
  printf '{"nvidia-gpu-passthrough": [], "amd-gpu-passthrough": [{"label": "AMD vLLM 0.29.0 - ROCm 10.1", "image": "%s:%s"}]}\n' "$ROCM_VLLM_IMAGE" "$ROCM_VLLM_TAG" \
    > "$ASSETS/nai-ui-patch/vllm-versions.generated.json"
  patched_image nai-api /app/nai-iep "python3 patch-nai-api-amdgpu.py orig nai-iep && chmod 755 nai-iep" "v$NAI_VERSION-amd" nai-api-patch
  patched_image nai-inference-ui /usr/share/nginx/html \
    "mv orig html && python3 patch-nai-ui-amdgpu.py html '$ROCM_VLLM_IMAGE:$ROCM_VLLM_TAG' vllm-versions.generated.json" "v$NAI_VERSION-amd4" nai-ui-patch
  ok "NAI patched for AMD: chart, nai-api:v$NAI_VERSION-amd, nai-inference-ui:v$NAI_VERSION-amd4"
}

nai_deps() {
  registry_ensure; mkdir -p "$VALUES"; cp "$ASSETS"/nai-values/*.yaml "$VALUES/"
  # Gateway API v1.5.1 (Envoy Gateway 1.8 needs ListenerSet; Kommander ships an older one) + Envoy Gateway CRDs, server-side (> 1 MB)
  hl template x "$CHARTS/gateway-crds-helm" --set crds.gatewayAPI.enabled=true --set crds.gatewayAPI.channel=standard --set crds.envoyGateway.enabled=false > "$VALUES/gwapi.yaml"
  hl template x "$CHARTS/gateway-crds-helm" --set crds.gatewayAPI.enabled=false --set crds.envoyGateway.enabled=true > "$VALUES/eg-crds.yaml"
  kc apply --server-side --force-conflicts -f "$VALUES/gwapi.yaml" >/dev/null; kc apply --server-side --force-conflicts -f "$VALUES/eg-crds.yaml" >/dev/null
  hinst eg "$CHARTS/gateway-helm" envoy-gateway-system 15m -f "$VALUES/envoy-gateway.yaml" --skip-crds; ok "Envoy Gateway"
  local c; for c in kserve-crd kserve-llmisvc-crd; do hinst $c "$CHARTS/$c" kserve 10m; done; ok "KServe CRDs"
  hinst lws "$CHARTS/lws" lws-system 15m -f "$VALUES/lws.yaml"; ok "LeaderWorkerSet"
  hinst opentelemetry-operator "$CHARTS/opentelemetry-operator" opentelemetry-operator-system 15m -f "$VALUES/otel-operator.yaml"; ok "OpenTelemetry"
  printf 'global:\n  storage:\n    storageClassName: nai-local\n' > "$VALUES/nai-operators.yaml"
  hinst nai-operators "$CHARTS/nai-operators" nai-system 25m -f "$VALUES/nai-operators.yaml"; ok "NAI operators"
  hinst kserve "$CHARTS/kserve-resources" kserve 15m -f "$VALUES/kserve.yaml"
  hinst kserve-llmisvc "$CHARTS/kserve-llmisvc-resources" kserve 15m -f "$VALUES/kserve-llmisvc.yaml"; ok "KServe"
}

nai_core() {
  registry_ensure
  { echo "# generated by nai-on-nkp.sh ($STACK stack)"
    echo "global:"
    echo "  storage: {storageClassName: nai-local, storageClassNameRWX: nai-nfs-storage}"
    echo "gateway:"
    echo "  globalRateLimit: {enabled: false}   # needs an Envoy rate-limit backend that is not deployed: every route would return 500"
    echo "  certManager: {selfSigned: true, dnsNames: [$NAI_DNS]}"
    if [ "$STACK" = moded ]; then
      echo "naiApi:"
      echo "  naiApiImage: {tag: v$NAI_VERSION-amd}"
      echo "  supportedVLLMROCmImage: $ROCM_VLLM_IMAGE"
      echo "  supportedVLLMROCmImageTag: $ROCM_VLLM_TAG"
      echo "naiInferenceUi:"
      echo "  naiUiImage: {tag: v$NAI_VERSION-amd4}"
    fi
  } > "$VALUES/nai-core.yaml"
  hinst nai-core "$CHARTS/nai-core" nai-system 40m -f "$VALUES/nai-core.yaml"; ok "NAI core"
}

nai_amd() {   # moded: admission webhook (nvidia.com/gpu -> amd.com/gpu for AMD endpoints), catalog runtimes, GPU metrics
  local D=$WORK/nai-amd-shim gids; mkdir -p "$D"; cp "$ASSETS"/nai-amd-shim/* "$D/"
  gids="$(getent group video | cut -d: -f3),$(getent group render | cut -d: -f3)"
  sed -i "s/__AMD_GPU_GROUPS__/$gids/" "$D/nai-amd-shim.yaml"
  sed -i "s#docker.io/nutanix/nai-python-processor:v[0-9.]*#docker.io/nutanix/nai-python-processor:v$NAI_VERSION#" "$D/nai-amd-shim.yaml"
  kc apply -f "$D/nai-amd-shim.yaml" >/dev/null
  kc -n nai-amd-shim create cm nai-amd-shim-code --from-file="$D/webhook.py" --dry-run=client -o yaml | kc apply -f - >/dev/null
  kc -n nai-amd-shim rollout restart deploy/nai-amd-shim >/dev/null 2>&1 || true
  kc -n nai-amd-shim rollout status deploy/nai-amd-shim --timeout=5m >/dev/null || die "nai-amd-shim webhook not ready"
  sed "s#__ROCM_IMAGE__#$ROCM_VLLM_IMAGE:$ROCM_VLLM_TAG#g" "$ASSETS/nai-catalog/nai-catalog-amd-runtimes.sql" > "$D/catalog.sql"
  kc -n nai-system exec -i nai-db-iep-1 -c postgres -- psql -q -v ON_ERROR_STOP=1 -U postgres -d nai_iep < "$D/catalog.sql" >> "$LOG" 2>&1 \
    && ok "AMD runtimes for validated catalog models: $(kc -n nai-system exec nai-db-iep-1 -c postgres -- psql -tAq -U postgres -d nai_iep -c "select count(*) from runtimes where name='vllm-amd-gpu-passthrough'")" \
    || warn "catalog runtimes not added (custom models still run on AMD)"
  local off=${NV_COUNT:-0}   # NAI charts key GPUs by index: shift AMD indices past the NVIDIA ones
  awk -v off="$off" '/sourceLabels: \[gpu_id\]/ {g = 1}
    g && /regex:/ {match($0, /"[0-9]+"/); n = substr($0, RSTART + 1, RLENGTH - 2)}
    g && /replacement:/ {sub(/"[0-9]+"/, "\"" n + off "\""); g = 0} {print}' "$D/nai-amd-gpu-monitor.yaml" > "$D/monitor.yaml"
  kc apply -f "$D/monitor.yaml" >/dev/null && ok "AMD GPU metrics mapped into NAI (GPU index offset $off)" || warn "AMD GPU metrics mapping not applied"
  ok "AMD endpoints: nai-amd-shim admission webhook active"
}

verify() {
  local i bad n
  kc get nodes --no-headers | grep -q ' Ready ' && ok "node Ready" || die "node not Ready"
  [ "${NV_COUNT:-0}" -gt 0 ] && { n=$(kc get node -o jsonpath='{.items[0].status.allocatable.nvidia\.com/gpu}'); [ "${n:-0}" -ge 1 ] && ok "nvidia.com/gpu: $n" || warn "no NVIDIA GPU allocatable"; }
  [ "$STACK" = moded ] && { n=$(kc get node -o jsonpath='{.items[0].status.allocatable.amd\.com/gpu}'); [ "${n:-0}" -ge 1 ] && ok "amd.com/gpu: $n" || warn "no AMD GPU allocatable"; }
  for i in $(seq 1 60); do
    bad=$(for ns in envoy-gateway-system kserve lws-system opentelemetry-operator-system nai-system nai-admin; do pods_ready $ns || echo -n "$ns "; done); [ -z "$bad" ] && break; sleep 15; done
  [ -z "$bad" ] && ok "all NAI pods running" || warn "pods not ready in: $bad"
  NAI_IP=$(kc -n nai-system get gateway nai-ingress-gateway -o jsonpath='{.status.addresses[0].value}' 2>/dev/null); save NAI_IP "$NAI_IP"
  [ -n "$NAI_IP" ] || die "the NAI gateway has no address (MetalLB range exhausted?)"
  local code; for i in $(seq 1 20); do code=$(curl -sk -m 10 -o /dev/null -w '%{http_code}' "https://$NAI_IP/nai" || true); [[ $code =~ ^(200|30[1-8])$ ]] && break; sleep 15; done
  [[ $code =~ ^(200|30[1-8])$ ]] && ok "NAI login page https://$NAI_IP/nai (HTTP $code)" || warn "NAI page not answering yet (HTTP $code)"
}

finish() {
  systemctl disable nai-nkp-resume.service >/dev/null 2>&1 || true
  { echo
    echo "======================================== ready ========================================"
    echo "Stack            : $STACK - NKP $NKP_VERSION cluster '$CLUSTER_NAME' + NAI $NAI_VERSION on $HOST_IP"
    echo "Kommander (NKP)  : https://${KOMMANDER_IP:-?}/dkp/kommander/dashboard"
    echo "   user and password: sudo nkp get dashboard --kubeconfig $KCFG"
    echo "   apply the NKP license there (Settings > Licensing)$([ "$STACK" = moded ] && echo '; the AMD GPU Operator app card shows once licensed')"
    echo "NAI              : https://${NAI_IP:-?}/nai"
    echo "   user admin, initial password: sudo kubectl --kubeconfig $KCFG -n nai-system get secret nai-default-user -o jsonpath='{.data.password}' | base64 -d"
    echo "   (changed at first login; then apply the NAI licence)"
    echo "kubectl          : kubeconfig $KCFG (also ~$INSTALL_USER/.kube/config)"
    echo "Models (NFS)     : import with source NFS: server $HOST_IP, share $MODEL_DIR"
    echo "Remove everything: sudo $SELF --uninstall"; } | tee -a "$TLOG"
}

# ---------------------------------------------------------------- uninstall (back to the OS default)
nkp_teardown() {   # everything NKP's provisioning (konvoy) put on the host
  log "removing the NKP cluster from this host"
  systemctl stop kubelet >/dev/null 2>&1 || true
  command -v kubeadm >/dev/null && kubeadm reset -f >> "$LOG" 2>&1 || true
  systemctl disable --now kubelet containerd >/dev/null 2>&1 || true
  pkill -f containerd-shim 2>/dev/null || true; sleep 2
  # detach every mount below these trees first (pod volumes, NFS/local PVs, netns, Calico's cgroup2 mount), deepest first;
  # deletes then stay on their own filesystem, so nothing outside is ever reached through a mount
  local t; findmnt -rn -o TARGET | grep -E '^/(var/lib/kubelet|run/containerd|var/lib/containerd|run/netns|run/calico|var/lib/calico)(/|$)' | sort -r \
    | while read -r t; do umount "$t" 2>/dev/null || umount -l "$t" 2>/dev/null || true; done
  rm -rf --one-file-system /etc/kubernetes /var/lib/etcd /var/lib/kubelet /var/lib/containerd /run/containerd /etc/containerd /opt/containerd \
         /etc/cni /opt/cni /var/lib/cni /var/lib/calico /run/calico /var/log/calico /etc/konvoy /etc/crictl.yaml /run/cdi /etc/cdi \
         /usr/local/nvidia /opt/dkp /var/log/pods /var/log/containers 2>>"$LOG" || warn "some NKP runtime files could not be removed (see $LOG; a reboot clears /run)"
  rm -rf /etc/systemd/system/containerd.service /etc/systemd/system/containerd.service.d /etc/systemd/system/kubelet.service.d \
         /etc/systemd/system/multi-user.target.wants/containerd.service /etc/systemd/system/multi-user.target.wants/kubelet.service \
         /etc/systemd/system/cloud-config.service.d/boot-order.conf /etc/systemd/system/cloud-final.service.d/boot-order.conf
  rm -f /usr/local/bin/containerd /usr/local/bin/containerd-shim-runc-v2 /usr/local/bin/containerd-stress /usr/local/bin/ctr /usr/local/sbin/runc
  rm -f /etc/sysctl.d/bridge-nf-call.conf /etc/sysctl.d/ipv4-ip_forward.conf /etc/sysctl.d/ipv6-forwarding.conf \
        /etc/modules-load.d/konvoy-br_netfilter.conf /etc/NetworkManager/conf.d/calico.conf
  sed -i '/^fs.inotify.max_user_instances=8192$/d; /^fs.inotify.max_user_watches=524288$/d' /etc/sysctl.conf 2>/dev/null || true
  rm -f "$UHOME/kubeadm-conf.yaml" /etc/apt/sources.list.d/offline.list               # konvoy's apt switch to its offline repo
  [ -f /etc/apt/sources.list.d/ubuntu.sources.disabled ] && [ ! -f /etc/apt/sources.list.d/ubuntu.sources ] \
    && mv /etc/apt/sources.list.d/ubuntu.sources.disabled /etc/apt/sources.list.d/ubuntu.sources
  local l; for l in $(ip -o link show | awk -F': ' '{print $2}' | cut -d@ -f1 | grep -E '^(cali|vxlan.calico|tunl0|kube-ipvs0|nodelocaldns)'); do ip link delete "$l" 2>/dev/null || true; done
  apt-mark unhold kubelet kubeadm kubectl cri-tools >/dev/null 2>&1 || true
  systemctl daemon-reload; ok "NKP removed from the host (Kubernetes, containerd, CNI, NKP's apt offline repo; Ubuntu sources restored)"
}

safe_purge() {   # purge recorded packages, but never one whose removal would also take a package the OS had before
  local want=() keep=() p extra
  for p in $(awk '$1=="PKG"{print $2}' "$MANIFEST" | sort -u); do dpkg -s "$p" >/dev/null 2>&1 && want+=("$p"); done
  [ ${#want[@]} = 0 ] && return 0
  echo "  checking ${#want[@]} recorded packages against the OS's own (simulated removal)" | tee -a "$TLOG"
  local set=" ${want[*]} " final=()
  for p in "${want[@]}"; do
    extra=$({ apt-get -s --allow-change-held-packages purge "$p" 2>/dev/null || true; } | awk '/^Purg /{print $2}' | while read -r x; do [[ $set == *" $x "* ]] || echo "$x"; done | head -3)
    if [ -n "$extra" ]; then keep+=("$p"); echo "    keeping $p (removing it would also remove: $(echo $extra))" >> "$LOG"; else final+=("$p"); fi
  done
  if [ "${PLAN:-0}" = 1 ]; then echo "  would remove ${#final[@]}: ${final[*]}"; [ ${#keep[@]} = 0 ] || { echo "  would keep ${#keep[@]} (the OS depends on them):"; grep "^    keeping" "$LOG" | tail -n ${#keep[@]}; }; return 0; fi
  [ ${#final[@]} -gt 0 ] && { DEBIAN_FRONTEND=noninteractive apt-get purge -y -qq --allow-change-held-packages "${final[@]}" >> "$LOG" 2>&1 || warn "some packages could not be removed (see $LOG)"; }
  ok "removed ${#final[@]} packages this setup installed"
  [ ${#keep[@]} = 0 ] || warn "kept ${#keep[@]} package(s) that packages from the OS install depend on: ${keep[*]}"
}

uninstall() {
  local yes=no; [ "${1:-}" = --yes ] && yes=yes
  [ -s "$MANIFEST" ] || { echo "nothing recorded by this script (no manifest in $STATE). For a hand-built lab run: sudo $SELF --adopt"; exit 0; }
  echo "${c_b}Uninstall${c_0}: returns this host to its OS default. It removes NKP (Kubernetes, containerd, registry), NAI,"
  echo "every AMD/NVIDIA modification and GPU driver this setup installed, the local volumes, the NFS export, and the"
  echo "packages recorded below - never a package the OS had before. Files you keep elsewhere are not touched."
  echo "Recorded changes:"; sed 's/^/   /' "$MANIFEST" | grep -v '^   PKG ' ; echo "   ... and $(grep -c '^PKG ' "$MANIFEST") packages"
  if [ $yes = no ]; then local a; a=$(ask "Type 'wipe' to continue"); [ "$a" = wipe ] || { echo "aborted"; exit 1; }; fi
  local models=no m reboot=no; m=$(awk '$1=="MODELDIR"{print $2}' "$MANIFEST" | head -1)
  if [ -n "$m" ]; then
    echo "Model storage $m ($(du -sh "$m" 2>/dev/null | cut -f1)) holds your NAI model files."
    [ $yes = no ] && [ "$(ask "Type 'delete-models' to delete it too, or Enter to keep it")" = delete-models ] && models=yes
  fi
  [ $yes = no ] && yesno "Reboot automatically when the uninstall is done (unloads removed drivers, clears Kubernetes network rules)" y && reboot=yes
  printf 'UN_MODELS=%s\nUN_REBOOT=%s\n' "$models" "$reboot" > "$STATE/uninstall.conf"
  # the rest runs as a background system job: stopping Kubernetes' networking can drop this SSH session
  UNLOG=/var/log/nai-nkp-uninstall.log; : > "$UNLOG"
  systemctl reset-failed nai-nkp-uninstall >/dev/null 2>&1 || true
  systemd-run -q --unit nai-nkp-uninstall --collect "$SELF" --uninstall-worker || die "could not start the uninstall job"
  echo "Uninstall running as a background job (survives a dropped SSH session). Follow it any time with:"
  echo "   sudo tail -f $UNLOG"
  follow_job nai-nkp-uninstall "$UNLOG"
}

follow_job() {   # unit log: show the job's log until it ends (Ctrl+C or a dropped session stops only the viewing)
  tail -n +"${3:-1}" -f "$2" & local t=$!
  while systemctl is-active -q "$1" 2>/dev/null || [ "$(systemctl show -p ActiveState --value "$1" 2>/dev/null)" = activating ]; do sleep 3; done
  sleep 2; kill $t 2>/dev/null || true
}

uninstall_run() {   # the job started by uninstall()
  local models reboot m; . "$STATE/uninstall.conf"; models=$UN_MODELS; reboot=$UN_REBOOT
  m=$(awk '$1=="MODELDIR"{print $2}' "$MANIFEST" | head -1)
  log "uninstall"
  systemctl disable --now nai-nkp-resume.service >/dev/null 2>&1 || true
  grep -qE '^(NKPHOST|NKPCLUSTER)' "$MANIFEST" && nkp_teardown
  local kind rest redo=no datadirs=""
  while read -r kind rest; do
    case $kind in
      CONTAINER)   podman rm -f "$rest" >/dev/null 2>&1 || true; ok "container $rest removed" ;;
      ENABLED)     systemctl disable "$rest" >/dev/null 2>&1 || true ;;
      SERVICE)     systemctl disable --now "$rest" >/dev/null 2>&1 || true; ok "service $rest stopped" ;;
      BLOCK)       local bf=${rest%% *} bt=${rest#* }
                   [ "$bf" = /etc/fstab ] && sed -n "\|^# BEGIN $MARK $bt\$|,\|^# END $MARK $bt\$|p" /etc/fstab | awk '$1 !~ /^#/ {print $2}' | sort -r | xargs -r -n1 umount -l 2>/dev/null || true
                   sed -i "\|^# BEGIN $MARK $bt\$|,\|^# END $MARK $bt\$|d" "$bf" ;;
      FSTABLINE)   umount -l "$(echo "$rest" | awk '{print $2}')" 2>/dev/null || true; grep -vxF "$rest" /etc/fstab > /etc/fstab.nai-nkp.tmp || true
                   cat /etc/fstab.nai-nkp.tmp > /etc/fstab; rm -f /etc/fstab.nai-nkp.tmp ;;
      EXPORTLINE)  grep -vxF "$rest" /etc/exports > /etc/exports.nai-nkp.tmp || true; cat /etc/exports.nai-nkp.tmp > /etc/exports; rm -f /etc/exports.nai-nkp.tmp ;;
      SWAP)        sed -i -E 's/^# disabled (by nai-on-nkp|for kubernetes): //' /etc/fstab; swapon -a 2>/dev/null || true; ok "swap re-enabled" ;;
      ENVLINE)     local ef=${rest%% *} el=${rest#* }; grep -vxF "$el" "$ef" > "$ef.nai-nkp.tmp" || true; cat "$ef.nai-nkp.tmp" > "$ef"; rm -f "$ef.nai-nkp.tmp" ;;
      RESTORE)     local rb=${rest%% *} rd=${rest#* }; [ -f "$rb" ] && cp -p "$rb" "$rd" ;;
      FILE)        rm -f "$rest" ;;
      DIR)         datadirs="$datadirs $rest" ;;
      AUTHKEY)     local af=${rest%% *} ac=${rest#* }; [ -f "$af" ] && sed -i "/ $ac\$/d" "$af" ;;
      GROUP)       gpasswd -d ${rest% *} ${rest#* } >/dev/null 2>&1 || true ;;
      INITRAMFS)   redo=yes ;;
      DATADIR)     datadirs="$datadirs $rest" ;;
    esac
  done < <(tac "$MANIFEST")
  exportfs -ra 2>/dev/null || true; systemctl daemon-reload
  if grep -qx "PKG podman" "$MANIFEST" && command -v podman >/dev/null; then podman system reset -f >/dev/null 2>&1 || true
    findmnt -rn -o TARGET | grep -E "^/var/lib/containers(/|$)" | sort -r | xargs -r -n1 umount -l 2>/dev/null || true; rm -rf --one-file-system /var/lib/containers /etc/containers/networks; fi
  safe_purge
  # dpkg keeps folders that hold files it did not install: Python caches of the purged ROCm tools
  local d; for d in /usr/share/amd_smi /usr/libexec/amdsmi_cli /usr/libexec/rocm_smi; do
    [ -d "$d" ] && ! dpkg -S "$d" >/dev/null 2>&1 || continue
    find "$d" -type d -name __pycache__ -prune -exec rm -rf {} + 2>/dev/null; find "$d" -depth -type d -empty -delete 2>/dev/null; done
  # kubectl's cache in ~/.kube, when this setup created that folder (its config was a new file, not a restored one)
  if grep -qx "FILE $UHOME/.kube/config" "$MANIFEST" && [ -d "$UHOME/.kube" ]; then
    rm -rf "$UHOME/.kube/cache" "$UHOME/.kube/http-cache"; rmdir "$UHOME/.kube" 2>/dev/null && ok "removed $UHOME/.kube" || true; fi
  command -v podman >/dev/null || { [ -d /var/lib/containers ] && grep -qx "PKG podman" "$MANIFEST" && rm -rf --one-file-system /var/lib/containers /etc/containers 2>/dev/null; true; }
  [ $redo = yes ] && { update-initramfs -u -k "$(uname -r)" >/dev/null 2>&1; ok "boot image rebuilt (GPU isolation removed)"; }
  for d in $datadirs; do   # never delete through a mount that is still attached (e.g. a kept model pool)
    [ -n "$d" ] && [ "$d" != / ] && [ -e "$d" ] || continue
    if findmnt -rn -o TARGET | grep -q "^$d\(/\|$\)"; then warn "$d still has a mount under it - left in place"; continue; fi
    rm -rf --one-file-system "$d"; ok "removed $d"; done
  [ $models = yes ] && [ -n "$m" ] && [ "$m" != / ] && { umount -l "$m" 2>/dev/null || true; rm -rf "$m"; ok "removed model storage $m"; }
  [ $models = no ] && [ -n "$m" ] && ok "model storage kept: $m"
  rm -rf "$STATE"
  echo "Uninstall complete. This log stays at /var/log/nai-nkp-uninstall.log."
  if [ "$reboot" = yes ]; then echo "Rebooting in 10 s (as agreed) to unload the removed drivers and clear Kubernetes network rules."; sleep 10; systemctl reboot
  else echo "Reboot when convenient (sudo reboot): it unloads the removed drivers and clears Kubernetes network rules."; fi
}

# ---------------------------------------------------------------- adopt: record a hand-built NKP + NAI lab
adopt() {
  [ -s "$MANIFEST" ] && grep -q '^ADOPTED' "$MANIFEST" && { echo "already adopted ($MANIFEST)"; exit 0; }
  local base keep u f l
  # OS baseline = end of the Ubuntu installer's (curtin's) last package transaction (it uses --force-unsafe-io)
  base=${BASELINE:-$(zcat -f $(ls -tr /var/log/apt/history.log*) 2>/dev/null | awk '/^Commandline:.*force-unsafe-io/ {c=1} /^End-Date:/ {if (c) e=$2" "$3; c=0} END {print e}')}
  [ -n "$base" ] || die "cannot tell when the OS was installed from /var/log/apt/history.log; set BASELINE='YYYY-MM-DD HH:MM:SS'"
  keep=${ADOPT_KEEP_PKGS:-"openssh-server ipmitool"}
  u=${SUDO_USER:-nutanix}; UHOME=$(user_home "$u")
  echo "Adopting the existing NKP + NAI lab: OS baseline $base; packages installed with ($keep) are kept."
  echo "ADOPTED $(date '+%F %T') baseline $base" >> "$MANIFEST"
  # packages: everything installed after the baseline that is still installed, except kept transactions and automatic upgrades
  zcat -f $(ls -tr /var/log/apt/history.log*) 2>/dev/null | awk -v base="$base" -v keep=" $keep " '
    /^Start-Date:/ {d=$2" "$3; c=""; skip=0}
    /^Commandline:/ {c=$0; n=split(keep, k, " "); for (i=1;i<=n;i++) if (k[i] != "" && index(c, k[i])) skip=1; if (c ~ /apt(-get)? (-y )?(dist-)?upgrade/) skip=1; ua = (c ~ /unattended-upgrade/)}
    /^Install:/ && d >= base && !skip {s=$0; sub(/^Install: /, "", s); gsub(/\([^)]*\)/, "", s); n=split(s, a, ","); for (i=1;i<=n;i++) {p=a[i]; gsub(/ /, "", p); sub(/:.*/, "", p); if (p != "" && !(ua && p ~ /^linux-(image|headers|modules|modules-extra|tools|cloud-tools|hwe)/ && p !~ /nvidia/)) print p}}' \
    | sort -u | while read -r p; do dpkg -s "$p" >/dev/null 2>&1 && rec "PKG $p"; done
  [ -d /etc/kubernetes ] && { rec "NKPHOST"; rec "NKPCLUSTER adopted"; }
  podman ps -a --format '{{.Names}}' 2>/dev/null | grep -qx nkp-registry && { rec "CONTAINER nkp-registry"
    f=$(podman inspect nkp-registry --format '{{range .Mounts}}{{.Source}} {{end}}' 2>/dev/null | awk '{print $1}'); [ -n "$f" ] && rec "DATADIR $f"; }
  systemctl is-enabled -q podman-restart.service 2>/dev/null && rec "ENABLED podman-restart.service"
  grep -E '^[^#].*[[:space:]](/mnt/disks/|/mnt/nai-disks/)' /etc/fstab | while read -r l; do rec "FSTABLINE $l"; done
  l=$(grep -E '^[^#]+\.img[[:space:]].*loop' /etc/fstab | head -1)
  if [ -n "$l" ]; then rec "FSTABLINE $l"; rec "MODELDIR $(echo "$l" | awk '{print $1}')"; rec "DIR $(echo "$l" | awk '{print $2}')"; fi
  grep -qE '^# disabled (for kubernetes|by nai-on-nkp): .*swap' /etc/fstab && rec "SWAP"
  grep -E '^/' /etc/exports 2>/dev/null | grep -E 'nai|nfs' | while read -r l; do rec "EXPORTLINE $l"; done
  for f in /etc/systemd/system/nfs-server.service.d/nai-pool.conf /etc/sudoers.d/90-nkp-$u /etc/containers/containers.conf /etc/sysctl.d/90-kind-inotify.conf \
           /etc/systemd/system/cloud-init.service /etc/systemd/system/cloud-init.target.wants/cloud-init.service /etc/profile.d/rocm-w7900.sh \
           /usr/local/bin/nkp /usr/local/bin/kubectl /usr/local/bin/helm "$UHOME/.ssh/nkp_ed25519" "$UHOME/.ssh/nkp_ed25519.pub" "$UHOME/kubeadm-conf.yaml"; do
    [ -e "$f" ] && rec "FILE $f"; done
  for f in /etc/modprobe.d/vfio-w6400.conf /etc/modules-load.d/vfio-w6400.conf /etc/modprobe.d/90-nai-nkp-vfio.conf; do [ -e "$f" ] && { rec "FILE $f"; rec "INITRAMFS"; }; done
  grep -q '^ROCR_VISIBLE_DEVICES=' /etc/environment 2>/dev/null && rec "ENVLINE /etc/environment $(grep '^ROCR_VISIBLE_DEVICES=' /etc/environment)"
  grep -q ' nkp-preprovisioned$' "$UHOME/.ssh/authorized_keys" 2>/dev/null && rec "AUTHKEY $UHOME/.ssh/authorized_keys nkp-preprovisioned"
  for g in render video; do id -nG "$u" | grep -qw $g && rec "GROUP $u $g"; done
  [ -d "$UHOME/.kube" ] && rec "DIR $UHOME/.kube"
  for f in /mnt/disks /mnt/nai-disks; do [ -d "$f" ] && rec "DIR $f"; done
  for f in $(grep -E '^[^#].*[[:space:]]/mnt/disks/' /etc/fstab | awk '{print $1}' | xargs -r -n1 dirname | sort -u); do rec "DATADIR $f"; done
  ok "recorded $(grep -c . "$MANIFEST") items ($(grep -c '^PKG ' "$MANIFEST") packages) in $MANIFEST"
  echo "Kept on purpose (not NKP/NAI): $keep, the W7900 fan service and overdrive option, the BMC fan mode, files in your home folder."
  echo "Review with: sudo $SELF --status    Remove with: sudo $SELF --uninstall"
}

status() {
  echo "State: $STATE"
  [ -d "$STATE" ] || { echo "Nothing installed by this script on this host."; return 0; }
  [ -f "$CONF" ] && echo "Stack: ${STACK:-?}, NKP ${NKP_VERSION:-?} '${CLUSTER_NAME:-?}', NAI ${NAI_VERSION:-?}, install ${INSTALL_DIR:-?}, models ${MODEL_DIR:-?}"
  echo "Finished stages:"; { ls -1tr "$DONE" 2>/dev/null || true; } | sed 's/^/  /'
  [ -s "$MANIFEST" ] && { echo "Recorded changes:"; grep -v '^PKG ' "$MANIFEST" | sed 's/^/  /'; echo "  + $(grep -c '^PKG ' "$MANIFEST") packages"; }
  [ -n "${KCFG:-}" ] && [ -f "$KCFG" ] && kc get nodes 2>/dev/null || true
}

# ---------------------------------------------------------------- main
[ "$(id -u)" = 0 ] || { echo "run with sudo"; exit 1; }
# read-only options (and an uninstall with nothing recorded) must not leave a state folder behind
case "${1:-}" in
  --status|--plan|--check|-h|--help) TLOG=/dev/null ;;
  --uninstall) TLOG=/dev/null; [ -s "$MANIFEST" ] || { echo "nothing recorded by this script (no manifest in $STATE)"; exit 0; } ;;
  *) mkdir -p "$STATE" "$DONE"; chmod 700 "$STATE"; touch "$MANIFEST" ;;
esac
[ -f "$CONF" ] && source "$CONF"
[ -n "${INSTALL_DIR:-}" ] && set_paths || UHOME=$(user_home "${SUDO_USER:-root}")
case "${1:-}" in
  --uninstall) uninstall "${2:-}"; exit 0 ;;
  --adopt)     adopt; exit 0 ;;
  --status)    status; exit 0 ;;
  --plan)      [ -s "$MANIFEST" ] || { echo "nothing recorded (install with this script, or --adopt a hand-built lab)"; exit 0; }
               echo "Read-only preview of --uninstall:"; grep -v '^PKG ' "$MANIFEST" | sed 's/^/   /'
               grep -qE '^(NKPHOST|NKPCLUSTER)' "$MANIFEST" && echo "   + full NKP teardown (Kubernetes, containerd, CNI, NKP apt offline repo -> Ubuntu sources)"
               PLAN=1 safe_purge; exit 0 ;;
  --check)     check; exit 0 ;;
  --uninstall-worker) INTERACTIVE=0; LOG=/var/log/nai-nkp-uninstall.log; exec >>"$LOG" 2>&1; TLOG=/dev/null; uninstall_run; exit 0 ;;
  --resume|--worker) INTERACTIVE=0; exec >>"$LOG" 2>&1; TLOG=/dev/null ;;
  -h|--help)   sed -n '2,27p' "$SELF"; exit 0 ;;
  "") ;;
  *) echo "unknown option $1 (see --help)"; exit 1 ;;
esac
grep -q '^ADOPTED' "$MANIFEST" && die "this host holds an adopted hand-built lab: run 'sudo $SELF --uninstall' first"
if [ "${1:-}" = "" ]; then   # interactive: questions here, then the long run continues as a background job
  exec 9>"$STATE/lock"; flock -n 9 || die "another run of this script is active (follow it: sudo tail -f $LOG)"
  stage inputs inputs
  exec 9>&-
  systemctl reset-failed nai-nkp-install >/dev/null 2>&1 || true
  local_start=$(( $(wc -l < "$LOG") + 1 ))
  systemd-run -q --unit nai-nkp-install --collect "$SELF" --worker || die "could not start the installation job"
  echo; echo "Installation running as a background job (survives a dropped SSH session). Follow it any time with:"
  echo "   sudo tail -f $LOG        (status: sudo $SELF --status)"
  follow_job nai-nkp-install "$LOG" "$local_start"
  exit 0
fi
exec 9>"$STATE/lock"; flock -n 9 || die "another run of this script is active"
log "nai-on-nkp setup (state in $STATE)"
stage inputs inputs
source "$CONF"; set_paths; export KUBECONFIG=$KCFG
stage download       download_all
source "$CONF"
stage host-check     check
stage host-packages  host_packages
stage gpu-drivers    gpu_drivers
stage os-prep        os_prep
stage tools          tools
stage registry       registry
[ -f "$REG_UNIT" ] && curl -fsS -m 5 "http://$REG/v2/" >/dev/null 2>&1 || { log "registry not running as a service: repairing"; registry; }
[ -f "$STATE/pkgs.pre-nkp" ] || pkg_list > "$STATE/pkgs.pre-nkp"
stage nkp-images     nkp_images
stage host-storage   host_storage
stage cluster        cluster
record_nkp_pkgs() { pkg_new "$STATE/pkgs.pre-nkp" | while read -r p; do rec "PKG $p"; done; }   # kubelet, kubeadm, ... from NKP's provisioning
stage nkp-packages   record_nkp_pkgs
stage kommander      kommander
stage storage        cluster_storage
stage nai-images     nai_images
if [ "$STACK" = moded ]; then
  stage amd-operator amd_operator
  stage rocm-image   rocm_image
  stage nai-patches  nai_patches
fi
stage nai-deps       nai_deps
stage nai-core       nai_core
[ "$STACK" = moded ] && stage nai-amd nai_amd
source "$CONF"
stage verify         verify
source "$CONF"; finish
