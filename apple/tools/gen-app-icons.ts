// Renders every app icon from apple/branding/logo.svg, the one source of the logo.
//
//   make icons
//
// iOS: one opaque 1024 px PNG (App Store Connect refuses an alpha channel, so ffmpeg drops it).
// macOS: the ten catalog sizes, a rounded square on Apple's 824 / 1024 icon grid with a transparent margin.
import { Resvg } from "@resvg/resvg-js";
import { spawnSync } from "node:child_process";
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const appleDir = join(dirname(fileURLToPath(import.meta.url)), "..");
const background = "#0b0b0f";
const markColor = "#ffffff";

const logo = readFileSync(join(appleDir, "branding/logo.svg"), "utf8");
const viewBox = /viewBox="0 0 ([\d.]+) ([\d.]+)"/.exec(logo);
if (!viewBox) throw new Error("logo.svg has no 0-origin viewBox");
const logoAspect = Number(viewBox[2]) / Number(viewBox[1]);
const logoBody = logo.replace(/^<svg[^>]*>/, "").replace(/<\/svg>\s*$/, "");

function iconSvg(plate: string, markWidth: number): string {
  const markHeight = markWidth * logoAspect;
  const x = (1024 - markWidth) / 2;
  const y = (1024 - markHeight) / 2;
  return `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024">${plate}<svg x="${x}" y="${y}" width="${markWidth}" height="${markHeight}" viewBox="0 0 ${viewBox![1]} ${viewBox![2]}" fill="${markColor}">${logoBody}</svg></svg>`;
}

function png(svg: string, width: number): Buffer {
  return new Resvg(svg, { fitTo: { mode: "width", value: width } }).render().asPng();
}

function writeIos(): void {
  const svg = iconSvg(`<rect width="1024" height="1024" fill="${background}"/>`, 720);
  const tmp = mkdtempSync(join(tmpdir(), "iris-icon-"));
  const input = join(tmp, "icon.png");
  writeFileSync(input, png(svg, 1024));
  const out = join(appleDir, "Iris/Assets.xcassets/AppIcon.appiconset/icon-1024.png");
  const flat = spawnSync("ffmpeg", ["-v", "error", "-y", "-i", input, "-pix_fmt", "rgb24", out], {
    stdio: "inherit",
  });
  rmSync(tmp, { recursive: true });
  if (flat.status !== 0) throw new Error("ffmpeg could not flatten the iOS icon");
}

function writeMac(): void {
  const svg = iconSvg(
    `<rect x="100" y="100" width="824" height="824" rx="185" fill="${background}"/>`,
    580,
  );
  const dir = join(appleDir, "IrisMac/Assets.xcassets/AppIcon.appiconset");
  const images = [16, 32, 128, 256, 512].flatMap((size) =>
    [1, 2].map((scale) => {
      const filename = `icon-${size}@${scale}x.png`;
      writeFileSync(join(dir, filename), png(svg, size * scale));
      return { filename, idiom: "mac", scale: `${scale}x`, size: `${size}x${size}` };
    }),
  );
  const contents = { images, info: { author: "xcode", version: 1 } };
  writeFileSync(join(dir, "Contents.json"), `${JSON.stringify(contents, null, 2)}\n`);
}

writeIos();
writeMac();
