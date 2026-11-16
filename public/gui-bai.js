(() => {
  "use strict";

  const $ = id => document.getElementById(id);
  const form = $("submissionForm"), fields = $("submissionFields"), button = $("submissionButton");
  const view = $("submissionView"), claim = $("claimForm"), choice = $("studentChoice");
  const google = $("googleButton"), signOut = $("studentSignOut");
  const status = $("studentStatus"), submissionStatus = $("submissionStatus");
  const historyList = $("studentHistoryList"), historyStatus = $("studentHistoryStatus");
  const teacher = form.elements.namedItem("teacher");
  const query = new URLSearchParams(location.search);
  const settings = window.CAY_SUPABASE;
  const imageTypes = new Set(["image/jpeg", "image/png", "image/webp"]);
  const dateFormat = new Intl.DateTimeFormat("vi-VN", {
    timeZone: "Asia/Ho_Chi_Minh", day: "2-digit", month: "2-digit", year: "numeric"
  });
  let draft = null, accountId = null;

  function message(target, text, kind) {
    target.textContent = text;
    target.toggleAttribute("data-error", kind === "error");
    target.toggleAttribute("data-success", kind === "success");
  }

  const student = window.CayStudentSession;
  const client = student?.client(settings);
  if (!client) {
    message(status, "Chưa tải được phần đăng nhập. Bạn thử tải lại trang nhé.", "error");
    return;
  }

  async function rpc(name, args) {
    const {data, error} = await client.rpc(name, args);
    if (error) throw error;
    return data;
  }

  function applyTeacherPreset() {
    const preset = query.get("co") || sessionStorage.getItem("cay-student-teacher");
    if (/^co-[1-4]$/.test(preset ?? "")) teacher.value = preset;
  }

  function showLogin(hint = "") {
    accountId = null;
    $("studentLogin").hidden = false;
    $("studentAccount").hidden = true;
    claim.hidden = form.hidden = $("studentHistory").hidden = true;
    google.disabled = false;
    message(status, hint, hint ? "error" : "");
  }

  function setProfile({student_number, student_name}) {
    student.showAccount(student_number + ". " + student_name);
    claim.hidden = true;
    form.hidden = $("studentHistory").hidden = false;
    applyTeacherPreset();
    message(status, "");
  }

  async function refreshHistory() {
    const author = accountId;
    try {
      const rows = await rpc("cay_list_student_submissions");
      if (author !== accountId) return;
      historyList.replaceChildren(...rows.map(row => {
        const item = document.createElement("li");
        const details = document.createElement("span");
        const name = [...teacher.options].find(option => option.value === row.teacher_slug)?.textContent.trim();
        details.textContent = [name, dateFormat.format(new Date(row.submitted_at)),
          row.published_at ? "Đã lên cây" : "Chờ đưa lên cây"].filter(Boolean).join(" · ");
        const link = document.createElement("a");
        link.className = "cay-submission-view";
        link.href = "./?bai=" + encodeURIComponent(row.id);
        link.textContent = "Xem trên cây";
        item.append(details, link);
        return item;
      }));
      historyStatus.textContent = rows.length ? "" : "Bạn chưa gửi bài nào.";
    } catch {
      if (author === accountId) historyStatus.textContent = "Chưa tải được danh sách bài. Bạn thử tải lại trang nhé.";
    }
  }

  async function loadRoster() {
    const rows = await rpc("cay_list_available_students");
    const placeholder = new Option("Chọn tên của bạn", "");
    choice.replaceChildren(placeholder, ...rows.map(row =>
      new Option(row.student_number + ". " + row.student_name, row.student_number)
    ));
    $("claimConfirmation").checked = false;
    claim.hidden = !rows.length;
    if (rows.length) choice.focus({preventScroll: true});
    message(status, rows.length ? "" : "Hiện chưa có tên nào để chọn. Bạn liên hệ người quản lý lớp nhé.");
  }

  async function start() {
    const code = query.get("code");
    if (code || query.has("error")) {
      history.replaceState(null, "", location.pathname);
      if (!code) return showLogin("Google chưa xác nhận đăng nhập. Bạn thử lại bằng Chrome hoặc Safari nhé.");
      const {error} = await client.auth.exchangeCodeForSession(code);
      if (error) return showLogin("Chưa hoàn tất đăng nhập Google. Bạn bấm đăng nhập lại nhé.");
    }
    const {data:{session}} = await client.auth.getSession();
    if (!session) return showLogin();
    accountId = session.user.id;
    $("studentLogin").hidden = true;
    student.showAccount(session.user.email ?? "Tài khoản Google");
    const [profile] = await rpc("cay_get_student_account");
    if (!profile) return loadRoster();
    setProfile(profile);
    await refreshHistory();
  }

  google.addEventListener("click", async () => {
    google.disabled = true;
    message(status, "Đang mở Google…");
    try {
      const preset = query.get("co");
      if (/^co-[1-4]$/.test(preset ?? "")) sessionStorage.setItem("cay-student-teacher", preset);
      await student.signIn(client);
    } catch {
      showLogin("Chưa mở được đăng nhập Google. Bạn thử lại sau nhé.");
    }
  });

  student.bindSignOut(client);

  client.auth.onAuthStateChange((event, session) => {
    if (accountId && (event === "SIGNED_OUT" || (session && session.user.id !== accountId))) {
      accountId = null;
      fields.disabled = true;
      student.returnToLogin();
    }
  });

  claim.addEventListener("submit", async event => {
    event.preventDefault();
    const claimButton = $("claimButton");
    if (claimButton.disabled) return;
    claimButton.disabled = true;
    try {
      const [profile] = await rpc("cay_claim_student_account", {p_student_number: Number(choice.value)});
      setProfile(profile);
      await refreshHistory();
    } catch (error) {
      if (error.code === "PT409") {
        try {
          const [profile] = await rpc("cay_get_student_account");
          if (profile) {
            setProfile(profile);
            await refreshHistory();
            return;
          }
          await loadRoster();
        } catch {
          message(status, "Chưa tải lại được danh sách lớp. Bạn thử tải lại trang nhé.", "error");
          return;
        }
      }
      message(status, error.code === "PT409" ? error.message : "Chưa xác nhận được tên. Bạn thử lại nhé.", "error");
    } finally {
      claimButton.disabled = false;
    }
  });

  function readDraft() {
    const wish = form.elements.namedItem("wish").value.trim();
    const story = form.elements.namedItem("story").value.trim();
    const photos = [...form.elements.namedItem("photos").files];
    if (!wish && !story) throw new Error("Bạn điền ít nhất một lời chúc hoặc lời tâm sự nhé.");
    if (photos.length > 3 || photos.some(file => !imageTypes.has(file.type) || !file.size || file.size > 10485760)) {
      throw new Error("Chọn tối đa 3 ảnh JPG, PNG hoặc WebP, mỗi ảnh tối đa 10 MB.");
    }
    return {id: crypto.randomUUID(), wish, story, destination: teacher.value, photos};
  }

  form.addEventListener("input", () => { draft = null; });
  form.addEventListener("change", () => { draft = null; });
  form.addEventListener("submit", async event => {
    event.preventDefault();
    if (fields.disabled || !accountId) return;
    try {
      draft ??= readDraft();
      const {id, wish, story, destination, photos} = draft;
      fields.disabled = signOut.disabled = true;
      view.hidden = true;
      button.textContent = "Đang gửi…";
      message(submissionStatus, "Đang kết nối…");
      const sent = await rpc("cay_begin_student_submission", {
        p_id: id, p_teacher_slug: destination, p_wish: wish, p_story: story
      });
      if (!sent) {
        for (const [index, file] of photos.entries()) {
          message(submissionStatus, "Đang tải ảnh " + (index + 1) + "/" + photos.length + "…");
          const {error} = await client.storage.from("cay-ki-uc")
            .upload("submission/" + id + "/" + (index + 1), file, {contentType: file.type});
          if (error && Number(error.statusCode ?? error.status) !== 409 && error.error !== "Duplicate") {
            throw new Error("Chưa tải được ảnh " + (index + 1) + ". Bấm Gửi bài để thử lại.");
          }
        }
        await rpc("cay_finish_student_submission", {p_id: id, p_photo_count: photos.length});
      }
      draft = null;
      form.reset();
      teacher.value = destination;
      view.href = "./?bai=" + encodeURIComponent(id);
      view.hidden = false;
      message(submissionStatus, "Đã nhận bài gửi. Bạn có thể xem lại ngay trên cây.", "success");
      view.focus();
      await refreshHistory();
    } catch (error) {
      if (error.code === "PT410") draft = null;
      const userError = error instanceof Error || ["22023", "PT410", "PT429", "42501"].includes(error.code);
      message(submissionStatus, userError ? error.message : "Chưa gửi được bài. Bấm Gửi bài để thử lại.", "error");
    } finally {
      fields.disabled = signOut.disabled = false;
      button.textContent = "Gửi bài";
    }
  });

  start().catch(error => {
    if (accountId) {
      message(status, error.code === "42501" ? error.message : "Chưa tải được tài khoản học sinh. Bạn thử tải lại trang nhé.", "error");
    } else {
      showLogin("Chưa kết nối được. Bạn thử tải lại trang nhé.");
    }
  });
})();
