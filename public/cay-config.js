window.CAY_SUPABASE = {
  url: "https://gjgmtvsikpycathqjeef.supabase.co",
  publishableKey: "sb_publishable_fiObqL6CQ0BmHdNrJ-Io3w_KISqbwSy"
};

(() => {
  "use strict";
  const defaults = Object.freeze({
    "co-1": "Cô Phùng Thị Việt Hà",
    "co-2": "Cô Ngô Thị Thùy Giang",
    "co-3": "Cô Ngô Thị Phượng",
    "co-4": "Cô Nguyễn Thị Cẩm Nhung"
  });
  const personalName = value => String(value ?? "").trim().replace(/^cô\s+/i,"").trim();
  let pendingNames;

  function load() {
    if (!pendingNames) {
      const {url,publishableKey} = window.CAY_SUPABASE;
      const endpoint = new URL("/rest/v1/rpc/cay_public_teacher_names",url);
      pendingNames = fetch(endpoint,{headers:{apikey:publishableKey}}).then(async response => {
        if (!response.ok) return defaults;
        const names = {...defaults};
        for (const {slug,name} of await response.json()) {
          const personal = personalName(name);
          if (Object.hasOwn(defaults,slug) && personal) names[slug] = "Cô " + personal;
        }
        return names;
      }).catch(() => defaults);
    }
    return pendingNames;
  }

  window.CAY_TEACHERS = {load,personalName};
  const labels = document.querySelectorAll("[data-cay-teacher]");
  if (labels.length) load().then(names => {
    for (const label of labels) {
      const name = names[label.dataset.cayTeacher];
      if (name) label.textContent = (label.dataset.cayTeacherPrefix ?? "") + name;
    }
  });
})();
