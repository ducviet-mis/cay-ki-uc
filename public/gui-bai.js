(() => {
  "use strict";

  const form = document.getElementById("submissionForm");
  const fields = document.getElementById("submissionFields");
  const button = document.getElementById("submissionButton");
  const status = document.getElementById("submissionStatus");
  const teacher = form.elements.namedItem("teacher");
  const preset = new URLSearchParams(location.search).get("co");
  if (/^co-[1-4]$/.test(preset ?? "")) teacher.value = preset;

  function message(text, kind) {
    status.textContent = text;
    status.toggleAttribute("data-error", kind === "error");
    status.toggleAttribute("data-success", kind === "success");
  }

  const settings = window.CAY_SUPABASE;
  if (!window.supabase || !settings?.url || !settings.publishableKey) {
    fields.disabled = true;
    message("Chưa tải được biểu mẫu. Bạn thử tải lại trang nhé.", "error");
    return;
  }
  const client = window.supabase.createClient(settings.url, settings.publishableKey, {
    auth: {storageKey: "cay-student-session", persistSession: true, detectSessionInUrl: false}
  });
  const imageTypes = new Set(["image/jpeg", "image/png", "image/webp"]);
  let draft = null;
  form.addEventListener("input", () => { draft = null; });
  form.addEventListener("change", () => { draft = null; });

  function readDraft() {
    const field = name => form.elements.namedItem(name).value.trim();
    const name = field("studentName"), number = Number(field("studentNumber"));
    const wish = field("wish"), story = field("story"), destination = field("teacher");
    const photos = [...form.elements.namedItem("photos").files];
    if (name.length < 2 || !Number.isInteger(number) || number < 1 || number > 10000 || !/^co-[1-4]$/.test(destination)) {
      throw new Error("Kiểm tra lại họ tên, số thứ tự và cô nhận nhé.");
    }
    if (!wish && !story) throw new Error("Bạn điền ít nhất một lời chúc hoặc lời tâm sự nhé.");
    if (photos.length > 3 || photos.some(file => !imageTypes.has(file.type) || !file.size || file.size > 10485760)) {
      throw new Error("Chọn tối đa 3 ảnh JPG, PNG hoặc WebP, mỗi ảnh tối đa 10 MB.");
    }
    return {id: crypto.randomUUID(), name, number, wish, story, destination, photos};
  }

  async function ensureSession() {
    const {data} = await client.auth.getSession();
    if (data.session) return;
    const {error} = await client.auth.signInAnonymously();
    if (error) throw new Error("Chưa mở được phiên gửi bài. Bạn thử lại sau ít phút nhé.");
  }

  async function rpc(name, args) {
    const {data, error} = await client.rpc(name, args);
    if (error) throw error;
    return data;
  }

  form.addEventListener("submit", async event => {
    event.preventDefault();
    if (fields.disabled) return;
    try {
      draft ??= readDraft();
      const {id, name, number, wish, story, destination, photos} = draft;
      fields.disabled = true;
      button.textContent = "Đang gửi…";
      message("Đang kết nối…");
      await ensureSession();

      const sent = await rpc("cay_begin_submission", {
        p_id: id, p_teacher_slug: destination, p_student_number: number, p_student_name: name, p_wish: wish, p_story: story
      });
      if (!sent) {
        for (const [index, file] of photos.entries()) {
          message("Đang tải ảnh " + (index + 1) + "/" + photos.length + "…");
          const {error} = await client.storage.from("cay-ki-uc").upload("submission/" + id + "/" + (index + 1), file, {contentType: file.type});
          if (error && Number(error.statusCode ?? error.status) !== 409 && error.error !== "Duplicate") {
            throw new Error("Chưa tải được ảnh " + (index + 1) + ". Bấm Gửi bài để thử lại.");
          }
        }
        message("Đang lưu bài…");
        await rpc("cay_finish_submission", {p_id: id, p_photo_count: photos.length});
      }

      draft = null;
      form.reset();
      form.elements.namedItem("studentName").value = name;
      form.elements.namedItem("studentNumber").value = String(number);
      message("Đã nhận bài gửi của bạn. Bài sẽ lên cây sau khi được nhập trong trang quản lý.", "success");
    } catch (error) {
      if (error.code === "PT410") draft = null;
      const userError = error instanceof Error || ["22023", "PT410", "PT429", "42501"].includes(error.code);
      message(userError ? error.message : "Chưa gửi được bài. Bấm Gửi bài để thử lại.", "error");
    } finally {
      fields.disabled = false;
      button.textContent = "Gửi bài";
    }
  });
})();
