(() => {
  const BOARD_LIST_SELECTORS = ["#pending-tasks", "#approved-tasks", "#other-tasks"];
  const STORAGE_KEY = "codex-dashboard-density";

  function ready(callback) {
    if (document.readyState === "loading") {
      document.addEventListener("DOMContentLoaded", callback, { once: true });
      return;
    }
    callback();
  }

  ready(() => {
    const searchInput = document.querySelector("#task-search-input");
    const searchNote = document.querySelector("#task-search-note");
    const densityButtons = Array.from(document.querySelectorAll("[data-density]"));
    const boardLists = BOARD_LIST_SELECTORS.map((selector) => document.querySelector(selector)).filter(Boolean);
    if (!searchInput || !searchNote || !boardLists.length) {
      return;
    }

    let activeTerm = "";
    let activeDensity = "comfortable";
    let isApplyingSearch = false;

    const escapePattern = (value) => value.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");

    function ensureEmptyState(list) {
      let node = list.querySelector(".search-empty-state");
      if (!node) {
        node = document.createElement("div");
        node.className = "search-empty-state";
        node.hidden = true;
        node.textContent = "No tasks in this column match the current search.";
        list.appendChild(node);
      }
      return node;
    }

    function highlightText(node, term) {
      if (!node || !node.dataset.originalText) {
        return;
      }
      if (!term) {
        node.innerHTML = node.dataset.originalText;
        return;
      }
      const escaped = escapePattern(term);
      if (!escaped) {
        node.innerHTML = node.dataset.originalText;
        return;
      }
      const matcher = new RegExp(`(${escaped})`, "ig");
      node.innerHTML = node.dataset.originalText.replace(matcher, "<mark>$1</mark>");
    }

    function syncHighlight(term) {
      document.querySelectorAll(".task-item .item-title, .task-item .item-copy").forEach((node) => {
        if (!node.dataset.originalText) {
          node.dataset.originalText = node.innerHTML;
        }
        highlightText(node, term);
      });
    }

    function updateDensity(value) {
      activeDensity = value === "compact" ? "compact" : "comfortable";
      document.body.dataset.density = activeDensity;
      densityButtons.forEach((button) => {
        button.classList.toggle("active", button.dataset.density === activeDensity);
      });
      try {
        window.localStorage.setItem(STORAGE_KEY, activeDensity);
      } catch {}
    }

    function applySearch() {
      if (isApplyingSearch) {
        return;
      }
      isApplyingSearch = true;

      const term = activeTerm.trim().toLowerCase();
      let visibleTotal = 0;
      let taskTotal = 0;

      boardLists.forEach((list) => {
        const cards = Array.from(list.querySelectorAll(".task-item"));
        const emptyState = ensureEmptyState(list);
        let visibleInList = 0;

        cards.forEach((card) => {
          const haystack = (card.textContent || "").toLowerCase();
          const matches = !term || haystack.includes(term);
          card.dataset.searchHidden = matches ? "false" : "true";
          visibleInList += matches ? 1 : 0;
          taskTotal += 1;
        });

        visibleTotal += visibleInList;
        emptyState.hidden = visibleInList !== 0 || term === "";
        const column = list.closest("[data-task-scope]");
        if (column) {
          column.dataset.searchEmpty = visibleInList === 0 && term !== "" ? "true" : "false";
        }
      });

      syncHighlight(term);

      if (!term) {
        searchNote.textContent = "Search and density tools apply instantly across all board columns. Press / to focus search.";
        isApplyingSearch = false;
        return;
      }

      searchNote.innerHTML = `<strong>${visibleTotal}</strong> of <strong>${taskTotal}</strong> tasks match “${term.replace(/</g, "&lt;").replace(/>/g, "&gt;")}”. Press Esc to clear.`;
      isApplyingSearch = false;
    }

    searchInput.addEventListener("input", () => {
      activeTerm = searchInput.value || "";
      applySearch();
    });

    densityButtons.forEach((button) => {
      button.addEventListener("click", () => updateDensity(button.dataset.density || "comfortable"));
    });

    document.addEventListener("keydown", (event) => {
      const target = event.target;
      const targetTag = target && target.tagName ? target.tagName.toLowerCase() : "";
      const editing = targetTag === "input" || targetTag === "textarea" || (target && target.isContentEditable);
      if (event.key === "/" && !editing) {
        event.preventDefault();
        searchInput.focus();
        searchInput.select();
        return;
      }
      if (event.key === "Escape" && document.activeElement === searchInput && searchInput.value) {
        searchInput.value = "";
        activeTerm = "";
        applySearch();
      }
    });

    const observer = new MutationObserver((mutations) => {
      if (isApplyingSearch) {
        return;
      }
      const hasStructuralChange = mutations.some((mutation) => mutation.type === "childList" && mutation.target.classList?.contains("list"));
      if (hasStructuralChange) {
        applySearch();
      }
    });
    boardLists.forEach((list) => observer.observe(list, { childList: true }));

    try {
      updateDensity(window.localStorage.getItem(STORAGE_KEY) || "comfortable");
    } catch {
      updateDensity("comfortable");
    }

    applySearch();
  });
})();
