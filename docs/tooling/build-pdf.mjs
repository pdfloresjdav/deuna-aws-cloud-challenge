// Build the consolidated assessment PDF from report.html using the system Chrome
// via puppeteer-core (no bundled Chromium download).
//
// Usage (from repo root): node docs/tooling/build-pdf.mjs
//   Override browser with PUPPETEER_EXECUTABLE_PATH if needed.
import fs from "fs";
import path from "path";
import { fileURLToPath } from "url";
import puppeteer from "puppeteer-core";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const repoRoot = path.resolve(__dirname, "../..");
const htmlPath = path.join(repoRoot, "docs/deliverables/report.html");
const pdfPath = path.join(
  repoRoot,
  "docs/deliverables/Deuna-AWS-Cloud-Engineering-Assessment.pdf"
);

function findChrome() {
  if (process.env.PUPPETEER_EXECUTABLE_PATH) return process.env.PUPPETEER_EXECUTABLE_PATH;
  const candidates = [
    "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
    "/Applications/Chromium.app/Contents/MacOS/Chromium",
    "/usr/bin/google-chrome",
    "/usr/bin/chromium",
    "/usr/bin/chromium-browser",
  ];
  for (const c of candidates) {
    if (fs.existsSync(c)) return c;
  }
  throw new Error("No Chrome/Chromium found; set PUPPETEER_EXECUTABLE_PATH.");
}

const footer = `<div style="font-size:8px;color:#8a97a5;width:100%;padding:0 16mm;display:flex;justify-content:space-between;">
  <span>Documento de evaluación técnica · ejemplos sintéticos · sin despliegue AWS</span>
  <span>Página <span class="pageNumber"></span> / <span class="totalPages"></span></span></div>`;
const header = `<div style="font-size:8px;color:#9aa7b5;width:100%;padding:0 16mm;text-align:right;">Deuna! — AWS Cloud Engineering Assessment</div>`;

const browser = await puppeteer.launch({
  executablePath: findChrome(),
  headless: "new",
  args: ["--no-sandbox", "--disable-gpu", "--disable-dev-shm-usage"],
});
try {
  const page = await browser.newPage();
  await page.goto("file://" + htmlPath, { waitUntil: "networkidle0", timeout: 120000 });
  await page.pdf({
    path: pdfPath,
    format: "A4",
    printBackground: true,
    displayHeaderFooter: true,
    headerTemplate: header,
    footerTemplate: footer,
    margin: { top: "18mm", bottom: "16mm", left: "15mm", right: "15mm" },
  });
  console.log("PDF written: " + pdfPath);
} finally {
  await browser.close();
}
