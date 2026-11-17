(() => {
  "use strict";

  const $ = id => document.getElementById(id);
  const form = $("submissionForm"), fields = $("submissionFields"), button = $("submissionButton");
  const view = $("submissionView"), claim = $("claimForm"), choice = $("studentChoice");
  const google = $("googleButton"), signOut = $("studentSignOut");
  const status = $("studentStatus"), submissionStatus = $("submissionStatus");
  const historyStatus = $("studentHistoryStatus"), historyDialog = $("historyDialog");
  const historyBody = $("historyEditBody"), historySave = $("historySave"), historyCancel = $("historyCancel");
  const teacher = form.elements.namedItem("teacher");
  const query = new URLSearchParams(location.search);
  const messageTargetKey = "cay-student-next-message";
  const isTeacher = value => /^co-[1-4]$/.test(value ?? "");
  let messageTarget = isTeacher(query.get("co")) ? query.get("co") : query.get("viet") === "1" ? "viet" : "";
  let messageKind = query.get("loai") === "nhan" ? "nhan" : "chuc";
  const settings = window.CAY_SUPABASE;
  const imageTypes = new Set(["image/jpeg", "image/png", "image/webp"]);
  const dateFormat = new Intl.DateTimeFormat("vi-VN", {
    timeZone: "Asia/Ho_Chi_Minh", day: "2-digit", month: "2-digit", year: "numeric"
  });
  let draft = null, accountId = null, editingItem = null, historyRequest = 0;

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

  function showLogin(hint = "") {
    accountId = null;
    $("studentLogin").hidden = false;
    $("studentAccount").hidden = true;
    claim.hidden = form.hidden = $("studentHistory").hidden = true;
    google.disabled = false;
    message(status, hint, hint ? "error" : "");
  }

  async function enterStudentPage({student_number, student_name}) {
    if (!messageTarget) {
      location.replace("./loi-chuc.html");
      return;
    }
    student.showAccount(student_number + ". " + student_name);
    claim.hidden = true;
    form.hidden = $("studentHistory").hidden = false;
    if (isTeacher(messageTarget)) {
      teacher.value = messageTarget;
      $("studentBack").href = "./?xem=" + messageTarget;
      $("studentBack").textContent = "Quay lại cây";
    }
    setupComposer();
    message(status, "");
    await refreshHistory();
  }

  function setupComposer() {
    const privateNote = messageKind === "nhan";
    const route = isTeacher(messageTarget) ? "?co=" + messageTarget : "?viet=1";
    $("composeWish").href = route + "&loai=chuc";
    $("composeNote").href = route + "&loai=nhan";
    $(privateNote ? "composeNote" : "composeWish").setAttribute("aria-current","page");
    $("composeTitle").textContent = privateNote ? "Thêm lời nhắn riêng" : "Thêm lời chúc";
    $("composeHint").textContent = privateNote
      ? "Chỉ bạn và cô nhận có thể đọc lời nhắn và mở ảnh. Bài gửi sẽ hiện ở bông hoa của bạn."
      : "Lời chúc hiện công khai trên cây ngay khi bạn gửi thành công.";
    $("composeWishField").hidden = privateNote;
    $("composeNoteField").hidden = $("composePhotosField").hidden = !privateNote;
    form.elements.namedItem("wish").required = !privateNote;
    form.elements.namedItem("story").required = privateNote;
    button.textContent = privateNote ? "Gửi lời nhắn riêng" : "Gửi lời chúc";
  }

  function receiptLink(id, kind) {
    return "./?bai=" + encodeURIComponent(id) + "&loai=" + kind;
  }

  function renderHistoryItem(row) {
    const privateNote = row.kind === "nhan";
    const title = privateNote ? "lời nhắn riêng" : "lời chúc";
    const item = document.createElement("li");
    const details = document.createElement("small");
    const name = [...teacher.options].find(option => option.value === row.teacher_slug)?.textContent.trim();
    details.textContent = [name, dateFormat.format(new Date(row.submitted_at)),
      row.on_tree ? (privateNote ? "Đang hiện ở bông hoa" : "Đang hiện trên cây") : "",
      row.photo_count ? row.photo_count + " ảnh" : ""].filter(Boolean).join(" · ");
    const preview = document.createElement("p");
    preview.textContent = row.body.length > 140 ? row.body.slice(0, 140) + "…" : row.body;
    preview.hidden = !row.body;
    const actions = document.createElement("div");
    actions.className = "cay-history-actions";
    const link = document.createElement("a");
    link.className = "cay-submission-view";
    link.href = receiptLink(row.id, row.kind);
    link.textContent = "Xem bài";
    const edit = document.createElement("button");
    edit.type = "button";
    edit.className = "cay-history-edit";
    edit.textContent = "Chỉnh sửa";
    edit.addEventListener("click", () => {
      editingItem = row;
      $("historyEditTitle").textContent = "Chỉnh sửa " + title;
      historyBody.maxLength = privateNote ? 12000 : 3000;
      historyBody.value = row.body;
      message($("historyEditStatus"), "");
      historyDialog.showModal();
    });
    const remove = document.createElement("button");
    remove.type = "button";
    remove.className = "cay-history-delete";
    remove.textContent = "Xóa";
    remove.addEventListener("click", async () => {
      if (!accountId || !window.confirm("Xóa " + title + " này" + (row.photo_count ? " và ảnh đính kèm?" : "?"))) return;
      remove.disabled = edit.disabled = true;
      const author = accountId;
      try {
        await changeHistoryItem(row, null);
        if (author !== accountId) return;
        item.remove();
        if (view.getAttribute("href") === link.getAttribute("href")) {
          view.hidden = true;
          message(submissionStatus, "");
        }
        message(historyStatus, "Đã xóa " + title + ".", "success");
        await refreshHistory();
      } catch {
        if (author === accountId) message(historyStatus, "Chưa xóa được bài. Bạn thử lại nhé.", "error");
      } finally {
        remove.disabled = edit.disabled = false;
      }
    });
    actions.append(link, edit, remove);
    item.append(details, preview, actions);
    return item;
  }

  function changeHistoryItem(row, body) {
    return rpc("cay_change_own_submission", {p_id: row.id, p_kind: row.kind, p_body: body});
  }

  historyCancel.addEventListener("click", () => historyDialog.close());
  historyDialog.addEventListener("cancel", event => {
    if (historySave.disabled) event.preventDefault();
  });
  historyDialog.addEventListener("close", () => { editingItem = null; });
  $("historyEditForm").addEventListener("submit", async event => {
    event.preventDefault();
    if (!accountId || !editingItem || historySave.disabled) return;
    const row = editingItem, body = historyBody.value.trim(), author = accountId;
    const editStatus = $("historyEditStatus");
    if (!body) {
      message(editStatus, "Bạn điền nội dung trước khi lưu nhé.", "error");
      return;
    }
    historySave.disabled = historyCancel.disabled = historyBody.disabled = true;
    message(editStatus, "Đang lưu…");
    try {
      await changeHistoryItem(row, body);
      if (author !== accountId) return;
      historyDialog.close();
      message(historyStatus, "Đã lưu chỉnh sửa.", "success");
      await refreshHistory();
    } catch (error) {
      if (author === accountId) message(editStatus, error.code === "22023" || error.code === "PT404"
        ? error.message : "Chưa lưu được bài. Bạn thử lại nhé.", "error");
    } finally {
      historySave.disabled = historyCancel.disabled = historyBody.disabled = false;
    }
  });

  async function refreshHistory() {
    const author = accountId, request = ++historyRequest;
    try {
      const rows = await rpc("cay_student_history");
      if (author !== accountId || request !== historyRequest) return;
      for (const [kind, id] of [["chuc", "historyWishes"], ["nhan", "historyNotes"]]) {
        const items = rows.filter(row => row.kind === kind);
        $(id).replaceChildren(...items.map(renderHistoryItem));
        $(id + "Empty").hidden = items.length > 0;
      }
      if (historyStatus.hasAttribute("data-error")) message(historyStatus, "");
    } catch {
      if (author === accountId && request === historyRequest) {
        message(historyStatus, "Chưa tải được danh sách bài. Bạn thử tải lại trang nhé.", "error");
      }
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
      const [pending, kind] = (sessionStorage.getItem(messageTargetKey) ?? "").split(":");
      sessionStorage.removeItem(messageTargetKey);
      if (pending === "viet" || isTeacher(pending)) messageTarget = pending;
      if (kind === "nhan" || kind === "chuc") messageKind = kind;
      const destination = isTeacher(messageTarget) ? "?co=" + messageTarget : messageTarget ? "?viet=1" : "";
      history.replaceState(null, "", location.pathname + (destination ? destination + "&loai=" + messageKind : ""));
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
    await enterStudentPage(profile);
  }

  google.addEventListener("click", async () => {
    google.disabled = true;
    message(status, "Đang mở Google…");
    try {
      await student.signIn(client, messageTarget ? messageTarget + ":" + messageKind : "");
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
      await enterStudentPage(profile);
    } catch (error) {
      if (error.code === "PT409") {
        try {
          const [profile] = await rpc("cay_get_student_account");
          if (profile) {
            await enterStudentPage(profile);
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
    const privateNote = messageKind === "nhan";
    const wish = privateNote ? "" : form.elements.namedItem("wish").value.trim();
    const story = privateNote ? form.elements.namedItem("story").value.trim() : "";
    const photos = privateNote ? [...form.elements.namedItem("photos").files] : [];
    if (!wish && !story) throw new Error(privateNote ? "Bạn điền lời nhắn riêng nhé." : "Bạn điền lời chúc nhé.");
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
      view.href = receiptLink(id, messageKind);
      view.hidden = false;
      message(submissionStatus, messageKind === "nhan"
        ? "Đã gửi lời nhắn riêng vào bông hoa của bạn."
        : "Lời chúc đã xuất hiện trên cây.", "success");
      view.focus();
      await refreshHistory();
    } catch (error) {
      if (error.code === "PT410") draft = null;
      const userError = error instanceof Error || ["22023", "PT410", "PT429", "42501"].includes(error.code);
      message(submissionStatus, userError ? error.message : "Chưa gửi được bài. Bấm Gửi bài để thử lại.", "error");
    } finally {
      fields.disabled = signOut.disabled = false;
      button.textContent = messageKind === "nhan" ? "Gửi lời nhắn riêng" : "Gửi lời chúc";
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
