# Turn `docker inspect` output of containers into a docker-compose YAML document.
#
# Input : array of container inspect objects
# Args  : $images  – object mapping image ID → image .Config (for diffing defaults)
#         $redact  – boolean; replace secret-looking env values with ${VAR} placeholders
#         $header  – string emitted verbatim at the top of the file
#         $managed – boolean; declare networks as compose-managed (pinned name) instead of external
#
# Only settings that differ from the image / engine defaults are emitted, so the
# output stays close to what a human would have written.

def q: tojson;                                   # JSON strings are valid YAML scalars
def esc: if type == "string" then gsub("\\$"; "$$") else . end;   # compose interpolation escape
def present: . != null and . != "" and . != [] and . != {} and . != false and . != 0;
def svcname: ascii_downcase | gsub("[^a-z0-9_.-]"; "-");
def bytes: if . == null or . == 0 then null
  else [[1073741824, "g"], [1048576, "m"], [1024, "k"]] as $u
    | . as $b | first(($u[] | select($b % .[0] == 0) | "\($b / .[0])\(.[1])"), $b) end;
def dur: if . == null or . == 0 then null else ((. / 1e9 | floor | tostring) + "s") end;

def kv_line($ind; $k; $v): "\($ind)\($k): \($v | if type == "string" then q else tostring end)";
def scalar($k; $v): if ($v | present) then [kv_line("    "; $k; $v)] else [] end;
def list($k; $a): if ($a // [] | length) > 0 then ["    \($k):"] + [($a // [])[] | "      - \(q)"] else [] end;
def map_block($k; $m): if ($m // {} | length) > 0
  then ["    \($k):"] + [($m | to_entries[] | kv_line("      "; .key; .value | esc))] else [] end;

def secret_key: test("PASS|SECRET|TOKEN|API_?KEY|PRIVATE|CREDENTIAL|AUTH"; "i");
def redact_env: if $redact then
    map(capture("^(?<k>[^=]*)=(?<v>.*)$") as $e
        | if ($e.k | secret_key) then "\($e.k)=${\($e.k)}" else "\($e.k)=\($e.v | esc)" end)
  else map(esc) end;

def ports:
  (.HostConfig.PortBindings // {}) | to_entries | map(
    (.key | split("/")) as [$cport, $proto] |
    (.value // [{}])[] |
    ((if (.HostIp // "") | IN("", "0.0.0.0", "::") then "" else "\(.HostIp):" end)
     + (if (.HostPort // "") == "" then "" else "\(.HostPort):" end)
     + $cport + (if $proto == "tcp" then "" else "/\($proto)" end))
  ) | unique;

def is_anon: test("^[0-9a-f]{64}$");

def mounts($img):
  [ .Mounts[]? |
    if .Type == "bind" then "\(.Source):\(.Destination)\(if .RW then "" else ":ro" end)"
    elif .Type == "volume" and (.Name | is_anon) then
      (.Destination as $d | if ($img.Volumes // {} | has($d)) then empty else $d end)
    elif .Type == "volume" then "\(.Name):\(.Destination)\(if .RW then "" else ":ro" end)"
    else empty end ];

def healthcheck($img):
  .Config.Healthcheck as $h |
  if $h == null or $h == $img.Healthcheck or ($h.Test // []) == [] then []
  elif $h.Test == ["NONE"] then ["    healthcheck:", "      disable: true"]
  else ["    healthcheck:", "      test: \($h.Test | map(esc) | q)"]
       + [ [["interval", ($h.Interval | dur)], ["timeout", ($h.Timeout | dur)],
            ["start_period", ($h.StartPeriod | dur)], ["retries", $h.Retries]][]
           | select(.[1] | present) | kv_line("      "; .[0]; .[1]) ]
  end;

def networking($names; $svc):
  (.Name | ltrimstr("/")) as $cname |
  (.HostConfig.NetworkMode // "default") as $mode |
  (.NetworkSettings.Networks // {}) as $nets |
  if $mode | IN("host", "none") then ["    network_mode: \($mode | q)"]
  elif $mode | startswith("container:") then
    ($mode | ltrimstr("container:")) as $id |
    ["    network_mode: \(("container:" + ($names[$id] // $id)) | q)"]
  elif ($nets | keys) == ["bridge"] or ($nets | length) == 0 then ["    network_mode: \"bridge\""]
  else
    ["    networks:"] +
    [ $nets | to_entries[] | select(.key != "bridge") |
      .value as $n |
      ([($n.Aliases // [])[] | select(test("^[0-9a-f]{12}$") or . == $cname or . == $svc | not)] | unique) as $aliases |
      ($n.IPAMConfig.IPv4Address // "") as $ip |
      if ($aliases | length) == 0 and $ip == "" then "      \(.key | q): {}"
      else "      \(.key | q):",
           (if $ip != "" then "        ipv4_address: \($ip | q)" else empty end),
           (if ($aliases | length) > 0 then "        aliases: \($aliases | q)" else empty end)
      end ]
  end;

def logging:
  .HostConfig.LogConfig as $l |
  if $l == null or ($l.Type == "json-file" and ($l.Config // {} | length) == 0) then []
  else ["    logging:", "      driver: \($l.Type | q)"]
       + (if ($l.Config // {} | length) > 0
          then ["      options:"] + [$l.Config | to_entries[] | kv_line("        "; .key; .value)] else [] end)
  end;

def restart:
  .HostConfig.RestartPolicy as $r |
  if ($r.Name // "no") | IN("no", "") then null
  elif $r.Name == "on-failure" and ($r.MaximumRetryCount // 0) > 0 then "on-failure:\($r.MaximumRetryCount)"
  else $r.Name end;

def service($img; $svc; $names):
  .Config as $cfg | .HostConfig as $hc |
  (($cfg.Env // []) - ($img.Env // [])) as $env |
  ($cfg.Labels // {} | with_entries(select(
      (.key | startswith("com.docker.compose.") | not)
      and ($img.Labels[.key] != .value)))) as $labels |
  ["  \($svc):"]
  + ["    image: \($cfg.Image | q)"]
  + ["    container_name: \(.Name | ltrimstr("/") | q)"]
  + scalar("hostname"; if $cfg.Hostname == .Id[0:12] or $hc.NetworkMode == "host" then null else $cfg.Hostname end)
  + scalar("restart"; restart)
  + (if $cfg.Entrypoint != $img.Entrypoint and $cfg.Entrypoint != null
       then ["    entrypoint: \($cfg.Entrypoint | map(esc) | q)"] else [] end)
  + (if $cfg.Cmd != $img.Cmd and $cfg.Cmd != null
       then ["    command: \($cfg.Cmd | map(esc) | q)"] else [] end)
  + scalar("user"; if $cfg.User != ($img.User // "") then $cfg.User else null end)
  + scalar("working_dir"; if $cfg.WorkingDir != ($img.WorkingDir // "") then $cfg.WorkingDir else null end)
  + list("ports"; ports)
  + list("environment"; $env | redact_env)
  + list("volumes"; mounts($img))
  + list("tmpfs"; ($hc.Tmpfs // {}) | to_entries | map(if .value == "" then .key else "\(.key):\(.value)" end))
  + networking($names; $svc)
  + list("extra_hosts"; $hc.ExtraHosts)
  + list("dns"; $hc.Dns)
  + list("dns_search"; $hc.DnsSearch)
  + scalar("privileged"; $hc.Privileged)
  + list("cap_add"; $hc.CapAdd)
  + list("cap_drop"; $hc.CapDrop)
  + list("security_opt"; $hc.SecurityOpt)
  + list("devices"; ($hc.Devices // []) | map("\(.PathOnHost):\(.PathInContainer)"))
  + list("group_add"; $hc.GroupAdd)
  + map_block("sysctls"; $hc.Sysctls)
  + scalar("pid"; $hc.PidMode)
  + scalar("ipc"; if ($hc.IpcMode // "") | IN("", "private", "shareable") then null else $hc.IpcMode end)
  + scalar("init"; $hc.Init)
  + scalar("runtime"; if ($hc.Runtime // "runc") == "runc" then null else $hc.Runtime end)
  + scalar("shm_size"; if ($hc.ShmSize // 67108864) == 67108864 then null else ($hc.ShmSize | bytes) end)
  + scalar("mem_limit"; $hc.Memory | bytes)
  + scalar("mem_reservation"; $hc.MemoryReservation | bytes)
  + scalar("memswap_limit"; if ($hc.MemorySwap // 0) > 0 and $hc.MemorySwap != (($hc.Memory // 0) * 2)
                            then ($hc.MemorySwap | bytes) else null end)
  + scalar("cpus"; if ($hc.NanoCpus // 0) > 0 then ($hc.NanoCpus / 1e9) else null end)
  + scalar("cpuset"; $hc.CpusetCpus)
  + scalar("tty"; $cfg.Tty)
  + scalar("stdin_open"; $cfg.OpenStdin)
  + scalar("stop_signal"; if $cfg.StopSignal != $img.StopSignal then $cfg.StopSignal else null end)
  + scalar("stop_grace_period"; if $cfg.StopTimeout then "\($cfg.StopTimeout)s" else null end)
  + (if ($hc.Ulimits // [] | length) > 0 then ["    ulimits:"]
       + [$hc.Ulimits[] | "      \(.Name): {soft: \(.Soft), hard: \(.Hard)}"] else [] end)
  + healthcheck($img)
  + logging
  + list("labels"; $labels | to_entries | map("\(.key)=\(.value | esc)"));

# ── Main ────────────────────────────────────────────────────────────────
. as $all |
($all | map({key: .Id, value: (.Name | ltrimstr("/"))}) | from_entries) as $names |
# service names: compose service label, else container name; fall back to container name on collisions
($all | map(.Config.Labels["com.docker.compose.service"] // (.Name | ltrimstr("/")) | svcname)) as $cand |
[ range(0; $all | length) as $i |
  $all[$i] as $c |
  (if ([$cand[] | select(. == $cand[$i])] | length) > 1 then ($c.Name | ltrimstr("/") | svcname) else $cand[$i] end) as $svc |
  $c | service($images[.Image] // {}; $svc; $names) | join("\n")
] as $services |
([$all[] | .Mounts[]? | select(.Type == "volume" and (.Name | is_anon | not)) | .Name] | unique) as $vols |
([$all[] | select((.HostConfig.NetworkMode // "") | IN("host", "none") | not)
         | .NetworkSettings.Networks // {} | keys[] | select(. != "bridge")] | unique) as $nets |
$header,
"services:",
($services | join("\n\n")),
(if ($vols | length) > 0 then
   "\n# Existing volumes are referenced as external so data is re-used, not recreated.\nvolumes:\n"
   + ($vols | map("  \(q):\n    external: true") | join("\n"))
 else empty end),
(if ($nets | length) > 0 then
   "\nnetworks:\n" + ($nets | map("  \(q):\n" + (if $managed then "    name: \(q)" else "    external: true" end)) | join("\n"))
 else empty end)
