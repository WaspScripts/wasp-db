import { createClient } from "npm:@supabase/supabase-js@2"

// Storage file name -> file names in the Simba build archive, newest naming first.
// The archive renamed its builds in August 2026 (Mac builds were briefly "darwin" on 2026/08-06),
// the old names are kept for older versions.
const platforms: Record<string, string[]> = {
	win64: ["Simba_windows_x86_64.exe", "Win64"],
	linux64: ["Simba_linux_x86_64", "Linux64"],
	"linux-arm64": ["Simba_linux_aarch64", "Linux arm64"],
	"mac-arm64": ["Simba_macos_aarch64", "Simba_darwin_aarch64", "Mac arm64"]
}

const ARCHIVE_URL = "https://github.com/Villavu/Simba-Build-Archive/raw/main/"
const VERSION_REGEX = /^[0-9a-f]{10}$/i
const FOLDER_REGEX = /^\/\d{4}\/\d{2}-\d{2}%20simba2000%20([0-9a-f]{10})\/$/i

const SECRET = Deno.env.get("SIMBA_FUNCTION_SECRET")

const supabase = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!)

async function sha256(value: string) {
	return new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(value)))
}

async function isAuthorized(req: Request) {
	const header = req.headers.get("x-simba-secret")
	if (!SECRET || !header) return false

	const [a, b] = await Promise.all([sha256(header), sha256(SECRET)])
	let diff = 0
	for (let i = 0; i < a.length; i++) diff |= a[i] ^ b[i]
	return diff === 0
}

async function download(url: string, names: string[]) {
	for (const name of names) {
		const res = await fetch(url + encodeURIComponent(name) + ".zip")
		if (res.ok) return res
		await res.body?.cancel()
	}
	return null
}

async function downloadUpload(url: string, filename: string, names: string[], version: string) {
	const res = await download(url, names)
	if (!res) {
		return { error: "Failed to download " + filename + " from " + url + ", tried: " + names.join(", ") }
	}

	const file = new Uint8Array(await res.arrayBuffer())

	const { error } = await supabase.storage.from("simba").upload(version + "/" + filename + ".zip", file, {
		contentType: "application/octet-stream",
		upsert: false
	})

	if (error) return { error: JSON.stringify(error) }
	return { error: null }
}

Deno.serve(async (req) => {
	if (!(await isAuthorized(req))) {
		return new Response("Unauthorized", { status: 401 })
	}

	const body = await req.json().catch(() => null)
	const version = body?.version
	if (typeof version !== "string" || !VERSION_REGEX.test(version)) {
		return new Response("Invalid JSON, version is missing or invalid", { status: 400 })
	}

	const { data, error } = await supabase
		.schema("scripts")
		.from("simba")
		.select("url")
		.eq("version", version)
		.maybeSingle()

	if (error) return new Response(JSON.stringify(error), { status: 500 })
	if (!data) return new Response("Unknown Simba version " + version, { status: 404 })

	const folder = FOLDER_REGEX.exec(data.url)
	if (!folder || folder[1].toLowerCase() !== version.toLowerCase()) {
		return new Response("Stored url for " + version + " is not a valid build folder: " + data.url, {
			status: 400
		})
	}

	const { data: existing, error: listError } = await supabase.storage.from("simba").list(version)
	if (listError) return new Response(JSON.stringify(listError), { status: 500 })

	const uploaded = new Set((existing ?? []).map((file) => file.name))
	const missing = Object.entries(platforms).filter(([filename]) => !uploaded.has(filename + ".zip"))
	if (missing.length === 0) return new Response("OK")

	const url = ARCHIVE_URL + data.url.slice(1)

	const results = await Promise.all(
		missing.map(([filename, names]) => downloadUpload(url, filename, names, version))
	)

	const errors = results.filter((result) => result.error).map((result) => result.error)
	if (errors.length > 0) return new Response(errors.join("\n"), { status: 400 })

	return new Response("OK")
})
