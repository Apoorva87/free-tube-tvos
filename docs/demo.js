const guide = document.querySelector("#walkthrough");
const scenes = [...guide.querySelectorAll(".scene")];
const sceneButtons = [...guide.querySelectorAll(".scene-controls button")];
const captions = {
  home: "Select a title to open the player. Scroll inside Home to explore both shelves.",
  player: "Try 1.5× or 2×, then choose Watch while browsing to carry the same session into Search.",
  mini: "Search the sample channels while the preview continues. Use the expand arrow to return to the player."
};
const library = {
  earth:   { title: "Earthrise", owner: "Orbital Journal", image: "earth" },
  saturn:  { title: "Inside Saturn’s rings", owner: "Ring Plane", image: "saturn" },
  mars:    { title: "Landing on Mars", owner: "Surface Lab", image: "mars" },
  jupiter: { title: "The Great Red Spot", owner: "Storm Atlas", image: "jupiter" },
  neptune: { title: "Beyond Neptune", owner: "Outer Worlds", image: "neptune" },
  horizon: { title: "A lunar horizon", owner: "Moon Notes", image: "earth" }
};
const duration = 240;
const clock = guide.querySelector(".clock");
const progress = guide.querySelector(".timeline i");
const toggle = guide.querySelector("#toggle");
const speed = guide.querySelector("#speed");
const search = guide.querySelector("#search-box");
let scene = "home";
let film = library.earth;
let seconds = 0;
let running = false;
let lastTick = performance.now();

function drawTime() {
  const whole = Math.floor(seconds);
  clock.value = Math.floor(whole / 60) + ":" + String(whole % 60).padStart(2, "0");
  progress.style.width = (100 * seconds / duration) + "%";
  toggle.textContent = running ? "Pause" : "Play";
  // A gentle pan conveys playback without embedding any external media player.
  const zoom = matchMedia("(prefers-reduced-motion: reduce)").matches ? 1 : 1 + 0.09 * seconds / duration;
  guide.querySelector(".play-art").style.transform = "scale(" + zoom + ")";
  guide.querySelector(".mini-art").style.objectPosition = "50% " + (50 + seconds / duration * 12) + "%";
}

function advance() {
  const now = performance.now();
  if (running && scene !== "home") {
    seconds = Math.min(duration, seconds + (now - lastTick) / 1000 * Number(speed.value));
    if (seconds >= duration) running = false;
  }
  lastTick = now;
  drawTime();
}

function showScene(next, focusInside = false) {
  advance();
  if (scene === "home" && next !== "home") running = true;
  if (next === "home") {
    running = false;
    seconds = 0;
  }
  scene = next;
  for (const panel of scenes) panel.hidden = panel.id !== next;
  for (const button of sceneButtons) button.setAttribute("aria-pressed", String(button.dataset.scene === next));
  guide.querySelector("#caption").textContent = captions[next];
  if (focusInside) {
    const control = next === "player" ? toggle : next === "mini" ? search : guide.querySelector(".tv-button");
    control.focus({ preventScroll: true });
  }
  drawTime();
}

function openFilm(key) {
  advance();
  film = library[key];
  seconds = 0;
  for (const element of guide.querySelectorAll(".film-title")) element.textContent = film.title;
  for (const element of guide.querySelectorAll(".film-owner")) element.textContent = film.owner;
  for (const image of guide.querySelectorAll(".play-art,.mini-art")) image.src = "assets/" + film.image + ".webp";
  showScene("player", true);
  running = true;
  drawTime();
}

function showMatches() {
  const matches = guide.querySelector("#matches");
  matches.replaceChildren();
  const term = search.value.trim().toLowerCase();
  for (const [key, entry] of Object.entries(library)) {
    if (!entry.owner.toLowerCase().includes(term)) continue;
    const button = document.createElement("button");
    button.type = "button";
    button.className = "match";
    button.textContent = entry.owner;
    button.setAttribute("aria-label", "Preview " + entry.title + " by " + entry.owner);
    button.dataset.film = key;
    matches.append(button);
  }
  if (!matches.childElementCount) matches.textContent = "No matching sample channels.";
}

guide.addEventListener("click", event => {
  const button = event.target.closest("button");
  if (!button) return;
  if (button.dataset.film) openFilm(button.dataset.film);
  else if (button.dataset.scene) showScene(button.dataset.scene, !button.closest(".scene-controls"));
});
toggle.addEventListener("click", () => {
  advance();
  if (seconds >= duration) seconds = 0;
  running = !running;
  drawTime();
});
search.addEventListener("input", showMatches);
speed.addEventListener("change", () => { lastTick = performance.now(); });
document.addEventListener("visibilitychange", () => { lastTick = performance.now(); });
window.setInterval(() => { if (!document.hidden && running) advance(); }, 250);
showMatches();
drawTime();
