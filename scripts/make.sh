#!/bin/sh -e

versions_json_url="https://launchermeta.mojang.com/mc/game/version_manifest.json"
resources_url="https://resources.download.minecraft.net"

fetch() {
	curl --fail -vsL "$@" || wget -v -O- "$@"
}

generate_download_list() {
	version="$1"
}

get_asset_index() {
	version="$1"

	echo "Fetching version list…" >&2
	case "$version" in
	release|snapshot)
		jq_filter='.latest.'"$version"' as $latestVersionID | .versions | map(select(.id == $latestVersionID)) [0]'
		;;
	*)
		version_json="$(printf '%s' "$version" | jq -R .)"
		jq_filter=".versions | map(select(.id == $version_json))"
		;;
	esac
	jq_filter="($jq_filter // {}) .url // \"\""
	version_json_url="$(fetch "$versions_json_url" | jq -r "$jq_filter")"
	if [ -z "$version_json_url" ]
	then
		return 1
	fi

	# get asset index json url
	asset_index_url="$(fetch "$version_json_url" | jq -r '.assetIndex.url')"

	# go through list of files
	asset_index_json="$(fetch "$asset_index_url")"
	cond=""
	filelist_json_path="$(mktemp)"
	printf '%s' "$asset_index_json" | jq -r '.objects|keys[]' | while read -r p; do case "$p" in *.ogg|*.wav|*.mp3) echo "$p" ;; esac; done | jq -R '.' > "$filelist_json_path"
	printf '%s' "$asset_index_json" | jq -r '. as $index | $files | map($index.objects[.].hash + " " + .) []' --slurpfile files "$filelist_json_path" || (
		exitcode=$?
		rm -f "$filelist_json_path"
		return $?
	)
	rm -f "$filelist_json_path"

	return 0
}

version="${1:-release}"
pack_format="${PACK_FORMAT:-12}"
sox_filter="${SOX_FILTER:-gain 100}"
base_version_dir="versions/$version"
assets_dir="$base_version_dir/assets"
target_dir="$base_version_dir/processed/sox-$(printf '%s' "$sox_filter" | sha512sum - | awk '{print $1}')"
processed_assets_dir="$target_dir/assets"

# Download asset index (filtered)
asset_index="$(get_asset_index "$version")"

# Generate aria2 input list file
input_list="$(mktemp)"
echo "$asset_index" | while read -r filehash filepath
do
	if [ -z "$filehash" ]
	then
		continue
	fi
	if [ -f "$assets_dir/$filepath" ]
	then
		continue
	fi
	echo "${resources_url}/$(printf '%s' "$filehash" | head -c2)/$filehash"
	echo "  out=$filepath"
done | aria2c --check-integrity --continue -x4 -i - --dir="$assets_dir" || (
	exitcode=$?
	rm -f "$input_list"
	exit $exitcode
)
rm -f "$input_list"

# Process each file
first_file="$processed_assets_dir/$(echo "$asset_index" | (read _ filepath _ && printf '%s' "$filepath"))"
echo "$asset_index" | while read -r _ filepath
do
	if [ -z "$filepath" ]
	then
		continue
	fi
	if [ -f "$processed_assets_dir/$filepath" ]
	then
		echo "Already existing: $filepath"
		continue
	fi
	echo "Processing: $filepath"
	mkdir -vp "$(dirname "$processed_assets_dir/$filepath")"
	tmppath="$(dirname "$processed_assets_dir/$filepath")/.tmp.$(basename "$filepath")"
	sox -D "$assets_dir/$filepath" "$tmppath" $sox_filter
	mv "$tmppath" "$processed_assets_dir/$filepath"
done

# Generate an example pack image
if [ ! -f pack.png ]
then
	if [ -z "$first_file" ]
	then
		echo "ERROR: Seemingly no file was generated?" >&2
		exit 1
	fi
	ffmpeg -hide_banner -loglevel error -i "$first_file" -filter_complex "aformat=channel_layouts=mono,showwavespic=s=16x16" -frames:v 1 -y "$target_dir/pack.png"
else
	install -m0644 pack.png "$target_dir/pack.png"
fi

# Generate pack definition
if [ -f pack.mcmeta ]
then
	install -m0644 pack.mcmeta "$target_dir/pack.mcmeta"
else
	# pack_format: https://minecraft.fandom.com/wiki/Pack_format
	echo '{"pack":{"description":"The default Minecraft sounds but it'"'"'s BOOSTED.","pack_format":'"$PACK_FORMAT"'}}' > "$target_dir/pack.mcmeta"
fi

mkdir -vp resourcepacks
resourcepacks_dir="$(readlink -f resourcepacks)"
resourcepack_zip_path="$resourcepacks_dir/Minecraft Modified ($version, $sox_filter).zip"
rm -f "$resourcepack_zip_path"
(cd "$target_dir"
	zip -r "$resourcepack_zip_path" .
)
