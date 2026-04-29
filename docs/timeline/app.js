// Yume Diary — render timeline entries chronologically with type filtering.
//
// To add an entry: write a new file under entries/, then import + add it to
// the array exported by entries/_index.js.

import { entries } from "./entries/_index.js";

const root = document.getElementById("timeline");

function renderHighlights(items) {
  if (!items || items.length === 0) return "";
  const lis = items.map(h => `<li>${h}</li>`).join("");
  return `<ul class="entry-highlights">${lis}</ul>`;
}

function renderMeta(entry) {
  const bits = [];
  if (entry.commit)    bits.push(`<strong>commit:</strong> <code>${entry.commit}</code>`);
  if (entry.files)     bits.push(`<strong>files:</strong> ${entry.files.map(f => `<code>${f}</code>`).join(", ")}`);
  if (entry.followups) bits.push(`<strong>followups:</strong> ${entry.followups.join(", ")}`);
  if (bits.length === 0) return "";
  return `<div class="entry-meta">${bits.join(" &nbsp;·&nbsp; ")}</div>`;
}

function renderEntry(entry) {
  const div = document.createElement("article");
  div.className = `entry t-${entry.type}`;
  div.dataset.type = entry.type;
  div.innerHTML = `
    <div class="entry-head">
      <span class="entry-date">${entry.date}</span>
      <span class="entry-type">${entry.type}</span>
    </div>
    <h2 class="entry-title">${entry.title}</h2>
    <p class="entry-summary">${entry.summary}</p>
    ${renderHighlights(entry.highlights)}
    ${renderMeta(entry)}
  `;
  return div;
}

function render(filter = "all") {
  // Sort by date asc, then by id (string compare) as tiebreaker
  const sorted = [...entries].sort((a, b) => {
    if (a.date !== b.date) return a.date.localeCompare(b.date);
    return a.id.localeCompare(b.id);
  });
  root.innerHTML = "";
  for (const entry of sorted) {
    const node = renderEntry(entry);
    if (filter !== "all" && entry.type !== filter) {
      node.classList.add("hidden");
    }
    root.appendChild(node);
  }
}

function wireFilters() {
  const buttons = document.querySelectorAll(".filter-btn");
  for (const btn of buttons) {
    btn.addEventListener("click", () => {
      buttons.forEach(b => b.classList.remove("active"));
      btn.classList.add("active");
      render(btn.dataset.type);
    });
  }
}

render();
wireFilters();
