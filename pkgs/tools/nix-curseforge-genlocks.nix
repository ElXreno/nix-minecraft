{
  writeShellApplication,
  curl,
  jq,
  unzip,
  coreutils,
  nix,
}:
writeShellApplication {
  name = "nix-curseforge-genlocks";

  runtimeInputs = [
    curl
    jq
    unzip
    coreutils
    nix
  ];

  text = ''
    set -euo pipefail

    if [ "$#" -lt 1 ] || [ "$1" = "-h" ] || [ "$1" = "--help" ]; then
      cat <<'EOF' >&2
    nix-curseforge-genlocks <zip-or-url> [output.json]

    Reads manifest.json from a CurseForge modpack and emits a lockfile
    consumable by fetchCurseForgeModpack.

    The first argument is either a local modpack ZIP path or a URL (any URL
    that resolves to a modpack ZIP works, including the CurseForge website
    redirect endpoint, e.g.
      https://www.curseforge.com/api/v1/mods/925200/files/7892974/download
    or a direct CDN URL).

    The lockfile is an array of { pid, fid, filename, sha1, url } objects
    sorted by fid. Default output path: ./locks.json.

    Requires CF_API_KEY in the environment. Get one at
    https://console.curseforge.com/.

    On success a paste-ready Nix snippet wiring fetchCurseForgeModpack +
    fetchurl (with the ZIP's sha256) is printed to stderr.
    EOF
      exit 1
    fi

    if [ -z "''${CF_API_KEY:-}" ]; then
      echo "error: CF_API_KEY environment variable is required" >&2
      exit 1
    fi

    input="$1"
    out="''${2:-./locks.json}"

    # Resolve input: path or URL → temp ZIP file.
    tmp=$(mktemp -d)
    trap 'rm -rf "$tmp"' EXIT

    zip_url=""
    zip_sha256=""

    if [ -f "$input" ]; then
      zip="$input"
    else
      echo "downloading modpack ZIP from $input ..." >&2
      # Follow redirects, capture the final URL for the snippet.
      zip="$tmp/modpack.zip"
      zip_url=$(curl -fL --retry 5 --retry-delay 2 \
        -w '%{url_effective}' -o "$zip" "$input")
    fi

    # Compute the ZIP's sha256 (SRI). Useful for the paste-ready snippet.
    zip_sha256=$(nix --extra-experimental-features nix-command \
      hash file --type sha256 --sri "$zip")

    manifest=$(unzip -p "$zip" manifest.json)
    if [ -z "$manifest" ]; then
      echo "error: manifest.json not found in modpack" >&2
      exit 1
    fi

    pack_name=$(echo "$manifest" | jq -r '.name // "curseforge-pack"')
    pack_version=$(echo "$manifest" | jq -r '.version // ""')
    mc_version=$(echo "$manifest" | jq -r '.minecraft.version // ""')
    primary_loader=$(echo "$manifest" \
      | jq -r '(.minecraft.modLoaders // []) | map(select(.primary == true))[0].id // .[0].id // ""')
    case "$primary_loader" in
      neoforge-*)      loader_type="neoforge"; loader_version="''${primary_loader#neoforge-}" ;;
      forge-*)         loader_type="forge";    loader_version="''${primary_loader#forge-}" ;;
      fabric-loader-*) loader_type="fabric";   loader_version="''${primary_loader#fabric-loader-}" ;;
      fabric-*)        loader_type="fabric";   loader_version="''${primary_loader#fabric-}" ;;
      quilt-*)         loader_type="quilt";    loader_version="''${primary_loader#quilt-}" ;;
      *)               loader_type="''${primary_loader%%-*}"; loader_version="''${primary_loader#*-}" ;;
    esac

    fids=$(echo "$manifest" | jq -c '[.files[] | select(.required == true) | .fileID]')
    fid_count=$(echo "$fids" | jq 'length')
    pids=$(echo "$manifest" | jq -c '[.files[] | select(.required == true) | .projectID] | unique')
    pid_count=$(echo "$pids" | jq 'length')
    echo "fetching metadata for $fid_count required files ($pid_count unique projects)..." >&2

    # Bulk endpoints take up to ~50 IDs in practice; chunk and accumulate
    # to a file (jq --argjson hits ARG_MAX on bigger chunks).
    chunk_size=50
    api_file="$tmp/api.jsonl"
    : > "$api_file"
    for ((start = 0; start < fid_count; start += chunk_size)); do
      chunk=$(echo "$fids" | jq -c ".[$start:$start+$chunk_size]")
      curl -sf \
        -H "x-api-key: $CF_API_KEY" \
        -H "Accept: application/json" \
        -H "Content-Type: application/json" \
        -X POST 'https://api.curseforge.com/v1/mods/files' \
        -d "{\"fileIds\": $chunk}" \
        | jq -c '.data[]' >> "$api_file"
    done

    # Bulk-fetch project metadata to map projectID → slug. The bulk-files
    # endpoint above only carries modId, but consumers (fetchCurseForgeModpack
    # + cf-exclude-include.json) match by slug.
    mods_file="$tmp/mods.jsonl"
    : > "$mods_file"
    for ((start = 0; start < pid_count; start += chunk_size)); do
      chunk=$(echo "$pids" | jq -c ".[$start:$start+$chunk_size]")
      curl -sf \
        -H "x-api-key: $CF_API_KEY" \
        -H "Accept: application/json" \
        -H "Content-Type: application/json" \
        -X POST 'https://api.curseforge.com/v1/mods' \
        -d "{\"modIds\": $chunk}" \
        | jq -c '.data[] | { id, slug }' >> "$mods_file"
    done

    # Build the locks object. For mods with downloadUrl == null (CF API
    # distribution disabled), fall back to the website redirect endpoint
    # which works for every project.
    manifest_file="$tmp/manifest.json"
    echo "$manifest" > "$manifest_file"

    # CF mod authors stash literal "Client"/"Server" strings inside the
    # gameVersions array (alongside real game versions like "1.21.1") to
    # signal intended side. We derive a 3-state side field per mod:
    #   - both "Server" and "Client" tags -> "both"
    #   - "Server" only                   -> "server"
    #   - "Client" only                   -> "client"
    #   - neither (untagged library)      -> "both"
    # The consumer (fetchCurseForgeModpack) filters out side="client" when
    # assembling a server install (and vice versa) and may ALSO filter
    # using a cf-exclude-include.json — that match keys on slug, which is
    # why each entry carries its slug.
    jq -n --arg mc "$mc_version" --arg ltype "$loader_type" --arg lver "$loader_version" \
      --slurpfile manifestArr "$manifest_file" \
      --slurpfile apiArr "$api_file" \
      --slurpfile modsArr "$mods_file" \
      '
        $manifestArr[0] as $manifest |
        $apiArr as $api |
        ($modsArr | map({key: (.id | tostring), value: .slug}) | from_entries) as $slugMap |
        {
          minecraft: $mc,
          loader: { type: $ltype, version: $lver },
          files: [
            $manifest.files[]
            | select(.required == true)
            | . as $entry
            | ($api | map(select(.id == $entry.fileID))[0]) as $file
            | (($file.gameVersions // []) | map(ascii_downcase)) as $gv
            | {
                pid: $entry.projectID,
                fid: $entry.fileID,
                slug: ($slugMap[$entry.projectID | tostring] // ""),
                filename: $file.fileName,
                sha1: ($file.hashes | map(select(.algo == 1))[0].value),
                url: ($file.downloadUrl // "https://www.curseforge.com/api/v1/mods/\($entry.projectID)/files/\($entry.fileID)/download"),
                side: (
                  ($gv | any(. == "server")) as $hasServer |
                  ($gv | any(. == "client")) as $hasClient |
                  if   $hasServer and $hasClient then "both"
                  elif $hasServer               then "server"
                  elif $hasClient               then "client"
                  else                                "both"  end
                )
              }
          ] | sort_by(.fid)
        }
      ' > "$out"

    echo "wrote $fid_count entries to $out" >&2

    # Paste-ready Nix snippet.
    cat >&2 <<EOF

    Drop this into your package:

    ----------------------------------------------------------------------
    {
      pkgs,
      fetchurl,
    }:
    pkgs.fetchCurseForgeModpack {
      pname = "$(echo "$pack_name" | tr ' ' '-')";
      version = "$pack_version";
      src = fetchurl {
        name = "$(echo "$pack_name" | tr ' ' '-')-$pack_version.zip";
    EOF

    if [ -n "$zip_url" ]; then
      cat >&2 <<EOF
        url = "$zip_url";
    EOF
    else
      cat >&2 <<EOF
        url = "<fill in: direct ZIP URL>";
    EOF
    fi

    cat >&2 <<EOF
        sha256 = "$zip_sha256";
      };
      locks = ./$(basename "$out");
    }

    # In your service module, the matching nix-minecraft server package is
    # available as <modpack>.serverPackage (resolved to ''${loader_type}Servers."''${loader_type}-$(echo "$mc_version" | tr . _)-$(echo "$loader_version" | tr . _)").
    ----------------------------------------------------------------------
    EOF
  '';
}
