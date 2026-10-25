const revealItems = document.querySelectorAll(".reveal");
if ("IntersectionObserver" in window) {
  const observer = new IntersectionObserver((entries) => {
    for (const entry of entries) {
      if (entry.isIntersecting) {
        entry.target.classList.add("visible");
        observer.unobserve(entry.target);
      }
    }
  }, { threshold: 0.12 });
  revealItems.forEach((item) => observer.observe(item));
} else {
  revealItems.forEach((item) => item.classList.add("visible"));
}

async function loadLatestRelease() {
  const status = document.querySelector("#release-status");
  try {
    const response = await fetch("https://api.github.com/repos/gokturksahis/GokturkOBS/releases/latest", { headers: { Accept: "application/vnd.github+json" } });
    if (!response.ok) return;
    const release = await response.json();
    if (!release.tag_name) return;
    const version = release.tag_name;
    status.textContent = version + " · Ücretsiz ve açık kaynak · macOS 26 veya üzeri";
    const dmg = (release.assets || []).find(asset => asset.name.toLowerCase().endsWith(".dmg"));
    if (dmg?.browser_download_url) document.querySelector("#download").href = dmg.browser_download_url;
  } catch {
    // The standard GitHub Releases link remains available if the API is unavailable.
  }
}
loadLatestRelease();
