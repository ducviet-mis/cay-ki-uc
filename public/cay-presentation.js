(() => {
  "use strict";

  // Đổi tên chung và lời dẫn ở đây. Dùng \n để ngắt dòng.
  // Để trống cả title, body, quote và note nếu muốn bỏ qua một màn.
  const CONFIG = {
    siteName: "Cây Kí Ức",
    slides: [
      { title: "20 / 11", body: "Ngày Nhà giáo Việt Nam", quote: "", note: "Chạm để tiếp tục" },
      {
        title: "Nguồn gốc",
        // Quyết định 167-HĐBT của Hội đồng Bộ trưởng, năm 1982.
        body: "Năm 1982, ngày 20 tháng 11 được chính thức chọn làm Ngày Nhà giáo Việt Nam.\nMỗi năm, ngày này là dịp để học trò gửi lời tri ân đến thầy cô.",
        quote: "", note: "Tiếp tục"
      },
      {
        title: "Ơn thầy, nghĩa cô",
        body: "Không thầy đố mày làm nên.",
        quote: "Ơn thầy theo bước ngày mai\nLời cô còn mãi, đường dài em đi.",
        note: "Tiếp tục"
      },
      {
        title: "Thầy cô không chỉ dạy chữ",
        body: "Thầy cô dạy ta biết đặt câu hỏi,\nbiết đứng dậy sau những lần vấp ngã,\nvà biết tin vào con đường mình chọn.",
        quote: "", note: "Tiếp tục"
      },
      {
        title: "Hôm nay, lớp gửi lại một chiếc cây",
        body: "Mỗi lời chúc là một chiếc lá, mỗi tâm sự là một bông hoa",
        quote: "", note: "Tiếp tục"
      }
    ]
  };

  const root = document.documentElement;
  const params = new URLSearchParams(location.search);
  const showWelcome = root.dataset.cayPage === "portal" &&
    params.get("admin") !== "1" && params.get("dang-nhap") !== "1" &&
    !params.has("bai") && !/^co-[1-4]$/.test(params.get("xem") ?? "");
  const slides = CONFIG.slides.map((slide,index)=>({...slide,index})).filter(slide=>
    [slide.title,slide.body,slide.quote,slide.note].some(value=>value?.trim()));
  if (showWelcome && slides.length) root.dataset.cayWelcome = "active";

  function decorate(container) {
    if (!container) return;
    const reduced = matchMedia("(prefers-reduced-motion: reduce)");
    const atmosphere = document.createElement("div");
    atmosphere.className = "cay-atmosphere";
    atmosphere.setAttribute("aria-hidden","true");
    const particles = [
      [9,21,15,-2,2],[18,70,19,-8,1],[27,42,13,-3,2],[37,81,22,-14,2],
      [43,18,16,-9,1],[56,63,18,-5,2],[62,29,14,-10,1],[73,76,21,-16,2],
      [81,37,17,-6,2],[92,59,22,-18,1],[14,-3,27,-10,7],[54,-4,34,-26,9],[86,-4,31,-18,8]
    ];
    for (const [x,y,life,delay,size] of particles) {
      const fleck = document.createElement("span");
      if (size > 2) fleck.className = "cay-petal";
      fleck.style.cssText = `--x:${x}%;--y:${y}%;--life:${life}s;--delay:${delay}s;--size:${size}px`;
      atmosphere.append(fleck);
    }
    container.prepend(atmosphere);
    if (reduced.matches || document.hidden) return;

    let started, frames = 0;
    function sample(now) {
      if (document.hidden) return;
      started ??= now;
      frames++;
      if (now-started < 850) requestAnimationFrame(sample);
      else if (frames*1000/(now-started) < 42) container.dataset.cayCalm = "";
    }
    requestAnimationFrame(sample);
    if (matchMedia("(pointer: fine)").matches) {
      let pending = 0, x = 0, y = 0;
      container.addEventListener("pointermove",event=>{
        if (reduced.matches || "cayCalm" in container.dataset || !root.dataset.cayWelcome) return;
        x = (event.clientX / innerWidth - .5) * 12;
        y = (event.clientY / innerHeight - .5) * 8;
        if (pending) return;
        pending = requestAnimationFrame(()=>{
          pending = 0;
          container.style.setProperty("--cay-drift-x",`${x}px`);
          container.style.setProperty("--cay-drift-y",`${y}px`);
        });
      },{passive:true});
    }
  }

  function setupLogin() {
    const password = document.getElementById("cayPassword");
    const reveal = document.getElementById("cayRevealCode");
    const status = document.getElementById("cayLoginStatus");
    const card = document.getElementById("cayLogin");
    const portal = document.getElementById("cayPortal");
    card.addEventListener("animationend",event=>{
      if (event.animationName === "cay-card-in") delete portal.dataset.cayCardReady;
    });
    reveal.addEventListener("click",()=>{
      const showing = password.type === "password";
      password.type = showing ? "text" : "password";
      reveal.textContent = showing ? "Ẩn mã" : "Hiện mã";
      reveal.setAttribute("aria-pressed",String(showing));
    });
    new MutationObserver(()=>{
      const incorrect = /^Mã .+chưa đúng/u.test(status.textContent);
      password.setAttribute("aria-invalid",String(incorrect));
      status.classList.toggle("cay-error",incorrect);
      card.classList.toggle("cay-shake",incorrect);
    }).observe(status,{childList:true,characterData:true,subtree:true});
    password.addEventListener("input",()=>{
      if (password.getAttribute("aria-invalid") === "true") {
        password.setAttribute("aria-invalid","false");
        status.textContent = "";
      }
    });
    if (window.visualViewport) {
      function fitKeyboard() {
        if (document.activeElement === password && visualViewport.height < innerHeight-80) {
          portal.style.setProperty("--cay-visible-height",`${visualViewport.height}px`);
          password.scrollIntoView({block:"nearest"});
        } else portal.style.removeProperty("--cay-visible-height");
      }
      visualViewport.addEventListener("resize",fitKeyboard,{passive:true});
      password.addEventListener("blur",()=>portal.style.removeProperty("--cay-visible-height"));
    }
    if (params.get("admin") === "1") password.focus({preventScroll:true});
  }

  function setupWelcome(entrance) {
    const portal = document.getElementById("cayPortal");
    const login = document.getElementById("cayLogin");
    const stage = document.getElementById("cayStoryStage");
    const story = document.getElementById("cayStoryLines");
    const progress = document.getElementById("cayStoryProgress");
    const replay = document.getElementById("cayStoryReplay");
    const skip = document.getElementById("cayStorySkip");
    const reduced = matchMedia("(prefers-reduced-motion: reduce)");
    const dots = [];
    let current = 0, busy = false, pointerStart;

    function drawStage(number) {
      portal.querySelectorAll("[data-cay-grow]").forEach(part=>{
        part.classList.toggle("is-drawn",Number(part.dataset.cayGrow) <= number);
      });
      portal.style.setProperty("--cay-drift-x","0px");
      portal.style.setProperty("--cay-drift-y","0px");
    }

    function render() {
      const slide = slides[current];
      story.replaceChildren();
      story.dataset.slide = String(slide.index+1);
      let line = 0;
      for (const [key,tag] of [["title","h1"],["body","p"],["quote","blockquote"]]) {
        for (const value of (slide[key] ?? "").split("\n").map(text=>text.trim()).filter(Boolean)) {
          const node = document.createElement(tag);
          node.className = `cay-story-${key} cay-story-line`;
          node.style.setProperty("--line",line++);
          node.textContent = value;
          story.append(node);
        }
      }
      if (slide.note?.trim()) {
        const action = document.createElement("button");
        action.type = "button";
        action.className = "cay-story-next cay-story-line";
        action.style.setProperty("--line",line);
        action.textContent = slide.note;
        story.append(action);
      }
      dots.forEach((dot,index)=>{
        if (index === current) dot.setAttribute("aria-current","step");
        else dot.removeAttribute("aria-current");
      });
    }

    function begin() {
      delete portal.dataset.cayCardReady;
      root.dataset.cayWelcome = "active";
      entrance.hidden = false;
      login.inert = true;
      current = 0;
      render();
      drawStage(slides[0].index+1);
      if (document.activeElement === replay) stage.focus({preventScroll:true});
    }

    function showLogin() {
      entrance.hidden = true;
      delete root.dataset.cayWelcome;
      login.inert = false;
      portal.dataset.cayCardReady = "";
      drawStage(5);
      const target = document.getElementById("cayLoginForm").hidden
        ? document.querySelector('#cayRolePicker button[aria-pressed="true"]')
        : document.getElementById("cayPassword");
      target?.focus({preventScroll:true});
    }

    function move(target) {
      if (busy || entrance.hidden || target === current) return;
      busy = true;
      story.dataset.leaving = "";
      drawStage(target >= slides.length ? 5 : slides[target].index+1);
      const leaveTime = reduced.matches ? 90 : 245;
      const moveTime = reduced.matches ? 180 : 825;
      setTimeout(()=>{
        delete story.dataset.leaving;
        if (target >= slides.length) showLogin();
        else {
          const focusLost = story.contains(document.activeElement);
          current = target;
          render();
          if (focusLost) stage.focus({preventScroll:true});
        }
      },leaveTime);
      setTimeout(()=>{busy=false;},moveTime);
    }

    slides.forEach((slide,index)=>{
      const dot = document.createElement("button");
      dot.type = "button";
      dot.setAttribute("aria-label",`Màn ${slide.index+1}`);
      dot.addEventListener("click",()=>move(index));
      dots.push(dot);
      progress.append(dot);
    });
    stage.addEventListener("click",event=>{
      if (event.detail !== 0 || event.target.closest(".cay-story-next")) move(current+1);
    });
    stage.addEventListener("pointerdown",event=>{
      pointerStart = event.pointerType==="touch" && event.isPrimary ? [event.clientX,event.clientY] : null;
    },{passive:true});
    stage.addEventListener("pointerup",event=>{
      if (!pointerStart) return;
      const dx=event.clientX-pointerStart[0], dy=event.clientY-pointerStart[1];
      pointerStart=null;
      if (Math.abs(dx) > 35 && Math.abs(dx) > Math.abs(dy)) move(current+1);
    },{passive:true});
    stage.addEventListener("pointercancel",()=>{pointerStart=null;},{passive:true});
    document.addEventListener("keydown",event=>{
      if (entrance.hidden || portal.hidden || event.repeat || event.defaultPrevented) return;
      if (event.key === "Escape") { event.preventDefault(); move(slides.length); return; }
      if (!["ArrowRight","Enter"," "].includes(event.key)) return;
      if (event.key !== "ArrowRight" && event.target.closest?.("button")) return;
      event.preventDefault();
      move(current+1);
    });
    skip.addEventListener("click",()=>move(slides.length));
    replay.addEventListener("click",()=>{
      if (!entrance.hidden || busy) return;
      busy = false;
      begin();
      stage.focus({preventScroll:true});
    });
    replay.hidden=false;
    begin();
  }

  function mount(config = CONFIG) {
    document.title = root.dataset.cayPage === "chooser" ? `Chọn cây · ${config.siteName}` : config.siteName;
    document.querySelectorAll("[data-cay-site-name]").forEach(element=>{
      element.textContent = (element.dataset.cayPrefix ?? "") + config.siteName;
    });
    const surface = document.querySelector("[data-cay-surface]");
    decorate(surface);
    if (root.dataset.cayPage !== "portal") return;
    setupLogin();
    if (showWelcome && slides.length) setupWelcome(document.getElementById("cayWelcome"));
  }

  window.CayPresentation = { config: CONFIG, mount };
})();
