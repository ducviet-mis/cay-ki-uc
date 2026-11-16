(() => {
  "use strict";
  const bucketName = "cay-ki-uc";
  const gallerySlots = 14;
  const seasons = ["Xuân", "Hạ", "Thu", "Đông"];
  const extensions = {"image/jpeg":"jpg", "image/png":"png", "image/webp":"webp"};
  const $ = id => document.getElementById(id);
  const clean = text => String(text ?? "").trim();
  let client;
  let guestReady = false;

  function result(response) {
    if (response.error) throw response.error;
    return response.data;
  }

  function photoRows(rows, slug) {
    const byKey = new Map(rows.map(row => [
      [row.teacher_slug || "",row.slot,row.season].join("/"),row
    ]));
    return Array.from({length:gallerySlots}, (_, i) => seasons.map((_, season) => [
      [slug,i+1,season], [slug,i+1,-1], ["",i+1,season], ["",i+1,-1]
    ].map(key => byKey.get(key.join("/"))).find(Boolean)));
  }

  async function galleryPhotos(gallery, slug, photoClient) {
    const photos = photoRows(gallery,slug);
    const paths = [...new Set(photos.flat().filter(Boolean).map(row => row.object_path))];
    const signed = paths.length
      ? result(await photoClient.storage.from(bucketName).createSignedUrls(paths, 3600))
      : [];
    const urls = new Map(signed.filter(item => item.signedUrl).map(item => [item.path,item.signedUrl]));
    return photos.map(rows => ({
      images:rows.map(row => urls.get(row?.object_path) ?? null),
      metaBySeason:rows.map(row => ({caption:row?.caption ?? "",date:row?.photo_date ?? ""})),
      caption:rows.find(Boolean)?.caption ?? "",
      date:rows.find(Boolean)?.photo_date ?? ""
    }));
  }

  async function loadSharedGallery(slug, url, publishableKey) {
    if (!window.supabase) return [];
    const guest = window.supabase.createClient(url,publishableKey,{
      auth:{persistSession:false,autoRefreshToken:false,detectSessionInUrl:false}
    });
    const gallery = result(await guest.from("cay_gallery")
      .select("slot,season,object_path,caption,photo_date").is("teacher_slug",null));
    return galleryPhotos(gallery,slug,guest);
  }

  async function loadTree(config, slug) {
    const responses = await Promise.all([
      client.from("cay_teachers").select("name,class_name,letter").eq("slug",slug).maybeSingle(),
      client.from("cay_students").select("number,name,class_roster").order("number"),
      client.from("cay_messages").select("student_number,wish,story,note_date,photo_paths").eq("teacher_slug",slug),
      client.from("cay_gallery").select("teacher_slug,slot,season,object_path,caption,photo_date")
    ]);
    const [teacher, allStudents, messages, gallery] = responses.map(result);
    if (!teacher) throw new Error("Chưa mở được cây. Cô thử nhập lại mã nhé.");
    const photos = await galleryPhotos(gallery,slug,client);
    const classRoster = allStudents.filter(student => student.class_roster);
    const roster = classRoster.length ? classRoster : allStudents;
    const byStudent = new Map(messages.map(row => [row.student_number,row]));
    config.teacherName = window.CAY_TEACHERS.personalName(teacher.name);
    config.className = teacher.class_name;
    config.intro.letter = {...config.intro.letter,...teacher.letter};
    config.students = roster.map(student => student.name);
    config.wishes = roster.map((student,index) => {
      const message = byStudent.get(student.number);
      return {student:index,text:message?.wish ?? "",date:message?.note_date ?? ""};
    });
    config.bushes.items = roster.map((student,index) => {
      const message = byStudent.get(student.number);
      return {student:index,story:message?.story ?? "",date:message?.note_date ?? "",photos:message?.photo_paths ?? []};
    });
    config.photos = photos;
  }

  async function loadPublicTree(config, slug, {url,publishableKey}) {
    const endpoint = new URL("/rest/v1/cay_public_wishes",url);
    endpoint.search = new URLSearchParams({select:"wish",teacher_slug:"eq." + slug,order:"wish.asc"});
    const classSizeUrl = new URL("/rest/v1/rpc/cay_class_size",url);
    const classSize = fetch(classSizeUrl,{headers:{apikey:publishableKey}})
      .then(response => response.ok ? response.json() : null)
      .catch(() => null);
    const [response, photos, teachers, rosterSize] = await Promise.all([
      fetch(endpoint,{headers:{apikey:publishableKey}}),
      loadSharedGallery(slug,url,publishableKey).catch(() => []),
      window.CAY_TEACHERS.load(),
      classSize
    ]);
    if (!response.ok) throw new Error("Chưa mở được cây công khai. Hãy tải lại trang để thử lại.");
    const wishes = await response.json();
    config.publicView = true;
    config.teacherName = window.CAY_TEACHERS.personalName(teachers[slug]);
    config.intro.enabled = true;
    config.intro.letter = {
      greeting:"Kính gửi cô [TÊN CÔ],",
      paragraphs:["Cảm ơn cô vì những ngày tháng cùng lớp. Mỗi tấm thiệp trên cây là một lời chúc chúng em gửi cô."],
      closing:"Thương mến,",
      signature:"Tập thể lớp"
    };
    const studentCount = Number.isSafeInteger(rosterSize) && rosterSize > 0 ? rosterSize : config.students.length;
    config.students = Array.from({length:Math.max(studentCount,wishes.length)},(_,i)=>"Bạn " + (i+1));
    config.wishes = wishes.map(({wish},student)=>({student,text:wish}));
    config.bushes.items = [];
    if (photos.length) config.photos = photos;
  }

  function photoFile(file) {
    if (!extensions[file?.type] || !file.size || file.size > 10485760) {
      throw new Error("Chọn ảnh JPG, PNG hoặc WebP, tối đa 10 MB mỗi ảnh.");
    }
    return file;
  }

  function randomId() {
    return Array.from(crypto.getRandomValues(new Uint8Array(16)), byte => byte.toString(16).padStart(2,"0")).join("");
  }

  async function upload(file, folder) {
    photoFile(file);
    const path = folder + "/" + randomId() + "." + extensions[file.type];
    result(await client.storage.from(bucketName).upload(path,file,{contentType:file.type}));
    return path;
  }

  // Chính sách lưu trữ chỉ cho xoá tệp không còn được tham chiếu.
  async function removeUnused(paths) {
    const unique = [...new Set(paths.filter(path => path && !path.startsWith("submission/")))];
    if (unique.length) await client.storage.from(bucketName).remove(unique);
  }

  function parseCsv(text) {
    const rows = [];
    let row = [], field = "", quoted = false;
    text = text.replace(/^\uFEFF/,"");
    for (let i = 0; i < text.length; i++) {
      const c = text[i];
      if (quoted && c === '"' && text[i+1] === '"') { field += '"'; i++; continue; }
      if (c === '"' && (quoted || !field)) { quoted = !quoted; continue; }
      if (!quoted && (c === "," || c === "\n" || c === "\r")) {
        row.push(field); field = "";
        if (c !== ",") {
          if (c === "\r" && text[i+1] === "\n") i++;
          rows.push(row); row = [];
        }
      } else field += c;
    }
    if (quoted) throw new Error("CSV có một ô thiếu dấu ngoặc kép đóng.");
    if (field || row.length) rows.push([...row,field]);
    return rows.filter(cells => cells.some(clean));
  }

  let workbookLibrary;
  function loadWorkbook() {
    if (window.XLSX?.version === "0.20.3") return Promise.resolve(window.XLSX);
    if (!workbookLibrary) {
      workbookLibrary = new Promise((resolve, reject) => {
        const script = document.createElement("script");
        script.src = "https://cdn.sheetjs.com/xlsx-0.20.3/package/dist/xlsx.mini.min.js";
        const fail = () => {
          script.remove();
          reject(new Error("Chưa tải được phần xử lý Excel. Vui lòng thử lại."));
        };
        script.addEventListener("load", () => window.XLSX?.version === "0.20.3" ? resolve(window.XLSX) : fail(), {once: true});
        script.addEventListener("error", fail, {once: true});
        document.head.append(script);
      }).catch(error => {
        workbookLibrary = null;
        throw error;
      });
    }
    return workbookLibrary;
  }

  async function workbookRows(file) {
    if (/\.csv$/i.test(file.name)) return parseCsv(await file.text());
    if (!/\.xlsx$/i.test(file.name) || file.size > 6 * 1024 * 1024) {
      throw new Error("Chọn tệp Excel .xlsx hoặc CSV, tối đa 6 MB.");
    }
    const XLSX = await loadWorkbook();
    try {
      const book = XLSX.read(await file.arrayBuffer(), {type: "array", sheetRows: 502, cellFormula: false});
      const sheet = book.Sheets[book.SheetNames[0]];
      if (!sheet) return [];
      const range = sheet["!fullref"] ?? sheet["!ref"];
      if (range && XLSX.utils.decode_range(range).e.r >= 501) {
        throw new RangeError("Mỗi lượt nhập tối đa 500 bài gửi. Vui lòng chia tệp thành các lượt nhỏ hơn.");
      }
      return XLSX.utils.sheet_to_json(sheet, {header: 1, defval: "", raw: false, blankrows: false});
    } catch (error) {
      if (error instanceof RangeError && error.message.startsWith("Mỗi lượt nhập")) throw error;
      throw new Error("Chưa đọc được tệp Excel. Hãy mở và lưu lại dưới dạng .xlsx rồi thử lại.");
    }
  }

  async function readRosterFile(file) {
    const data = await workbookRows(file);
    const key = value => clean(value).normalize("NFD").replace(/\p{Diacritic}/gu, "")
      .toLowerCase().replace(/[^a-z0-9]/g, "");
    const numberColumn = value => ["stt","sothutu","mahocsinh"].includes(key(value));
    const nameColumn = value => ["hovaten","hoten","hovatenhocsinh","hotenhocsinh"].includes(key(value));
    const header = data.findIndex(row => row.some(numberColumn) && row.some(nameColumn));
    if (header < 0) throw new Error("Tệp danh sách cần có cột STT và Họ và tên.");
    const numbers = data[header].findIndex(numberColumn);
    const names = data[header].findIndex(nameColumn);
    return data.slice(header + 1).filter(row => clean(row[numbers]) || clean(row[names]))
      .map(row => clean(row[numbers]) + "," + clean(row[names])).join("\n");
  }

  async function exportMessages() {
    const rows = result(await client.rpc("cay_export_submissions"));
    if (!rows.length) return "Chưa có bài mới để xuất.";
    const XLSX = await loadWorkbook();
    const formatDate = new Intl.DateTimeFormat("vi-VN", {
      timeZone: "Asia/Ho_Chi_Minh", day: "2-digit", month: "2-digit", year: "numeric"
    });
    const cells = [
      ["co","ma_hoc_sinh","ho_ten","loi_chuc","tam_su","ngay","ma_bai_gui","so_anh"],
      ...rows.map(row => [row.teacher_slug, "HS" + String(row.student_number).padStart(2, "0"), row.student_name,
        row.wish, row.story, formatDate.format(new Date(row.submitted_at)), row.id, row.photo_count])
    ];
    const sheet = XLSX.utils.aoa_to_sheet(cells);
    sheet["!cols"] = [9, 14, 26, 46, 54, 14, 39, 9].map(wch => ({wch}));
    const book = XLSX.utils.book_new();
    XLSX.utils.book_append_sheet(book, sheet, "Bài gửi");
    XLSX.writeFile(book, "bai-gui-cay-ki-uc.xlsx", {compression: true});
    return "Đã xuất " + rows.length + " bài gửi.";
  }

  async function importMessages(form, teachers, roster) {
    const selected = $("cayCsv").files[0];
    if (!selected) throw new Error("Chọn tệp Excel hoặc CSV cần nhập.");
    const [head = [], ...records] = await workbookRows(selected);
    const columns = head.map(clean);
    const required = ["ma_hoc_sinh","loi_chuc","tam_su"];
    if (!records.length || required.some(name => !columns.includes(name))) {
      throw new Error("Tệp cần dữ liệu và các cột ma_hoc_sinh, loi_chuc, tam_su.");
    }
    if (new Set(columns).size !== columns.length) throw new Error("Tên cột trong tệp bị trùng.");
    const linked = columns.includes("ma_bai_gui");
    if (linked && (!columns.includes("ho_ten") || !columns.includes("co"))) {
      throw new Error("Excel của biểu mẫu cần đủ các cột co, ho_ten và ma_bai_gui.");
    }
    if (linked && records.length > 500) throw new Error("Mỗi lượt nhập tối đa 500 bài gửi.");
    const photoColumns = linked ? [] : ["anh_1","anh_2","anh_3"].filter(name => columns.includes(name));
    const files = new Map();
    for (const file of $("cayCsvPhotos").files) {
      if (files.has(file.name)) throw new Error("Trùng tên tệp ảnh " + file.name + ".");
      files.set(file.name,file);
    }
    const teacherSlugs = new Set(teachers.map(teacher => teacher.slug));
    const numbers = new Set(roster.map(student => student.number));
    const keys = new Set();
    const items = records.map((values,index) => {
      const field = name => String(values[columns.indexOf(name)] ?? "");
      const teacher_slug = clean(field("co")) || form.elements.namedItem("teacher").value;
      const code = clean(field("ma_hoc_sinh")).match(/^(?:HS)?([0-9]+)$/i);
      const student_number = Number(code?.[1]);
      const key = teacher_slug + "/" + student_number;
      const validStudent = linked ? Number.isInteger(student_number) && student_number >= 1 && student_number <= 10000
        : numbers.has(student_number);
      if (values.length !== columns.length || !teacherSlugs.has(teacher_slug) || !validStudent || keys.has(key)) {
        throw new Error("Dòng " + (index + 2) + " có sai số cột, mã cô/học sinh hoặc bài bị trùng.");
      }
      keys.add(key);
      const row = {teacher_slug, student_number, wish:field("loi_chuc"), story:field("tam_su"), note_date:clean(field("ngay"))};
      if (linked) {
        const submission_id = clean(field("ma_bai_gui")), student_name = clean(field("ho_ten"));
        if (!/^[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12}$/i.test(submission_id) || student_name.length < 2) {
          throw new Error("Kiểm tra họ tên và mã bài gửi ở dòng " + (index + 2) + ".");
        }
        return {row: {...row, submission_id, student_name}};
      }
      const names = photoColumns.map(name => clean(field(name))).filter(Boolean);
      const images = names.map(name => {
        if (!files.has(name)) throw new Error("Thiếu tệp " + name + " ở dòng " + (index + 2) + ".");
        return photoFile(files.get(name));
      });
      return {row,images};
    });
    if (linked) {
      return result(await client.rpc("cay_publish_submissions", {p_rows: items.map(({row}) => row)}));
    }
    const oldPaths = new Map();
    if (photoColumns.length) {
      const current = result(await client.from("cay_messages")
        .select("teacher_slug,student_number,photo_paths").in("teacher_slug",[...new Set(items.map(item => item.row.teacher_slug))]));
      for (const row of current) oldPaths.set(row.teacher_slug + "/" + row.student_number,row.photo_paths);
    }
    const added = [];
    try {
      for (const {row,images} of items) {
        if (!photoColumns.length) continue;
        row.photo_paths = [];
        for (const file of images) {
          const path = await upload(file,"story");
          row.photo_paths.push(path);
          added.push(path);
        }
      }
      result(await client.from("cay_messages").upsert(items.map(item => item.row),
        {onConflict:"teacher_slug,student_number",defaultToNull:false}));
    } catch (error) {
      await removeUnused(added);
      throw error;
    }
    await removeUnused(items.flatMap(({row}) => oldPaths.get(row.teacher_slug + "/" + row.student_number) ?? []));
    return items.length;
  }

  async function signOut() {
    try { await client.auth.signOut({scope:"local"}); }
    finally { location.reload(); }
  }

  function option(value,label) {
    return new Option(label,String(value));
  }

  function action(form, status, run, pending = "Đang lưu…") {
    form.addEventListener("submit",async event => {
      event.preventDefault();
      const controls = [...form.elements].filter(control => !control.disabled);
      controls.forEach(control => control.disabled = true);
      status.textContent = pending;
      try { status.textContent = await run(event); }
      catch (error) { status.textContent = error.message || "Thao tác chưa hoàn tất."; }
      finally { controls.forEach(control => control.disabled = false); }
    });
  }

  async function openAdmin() {
    if (!result(await client.rpc("cay_is_admin"))) throw new Error("Tài khoản chưa có quyền quản lý.");
    const [teachers,roster] = (await Promise.all([
      client.from("cay_teachers").select("slug,name,class_name,letter").order("slug"),
      client.from("cay_students").select("number,name").order("number")
    ])).map(result);
    let gallery = result(await client.from("cay_gallery").select("*"));
    const cover = $("cayGallery"), scope = $("cayScope"), slot = $("caySlot"), season = $("caySeason");
    const profile = $("cayProfile"), profileTeacher = $("cayProfileTeacher");
    for (const teacher of teachers) {
      for (const select of [scope,$("cayImportTeacher"),profileTeacher]) {
        select.add(option(teacher.slug,teacher.name + " (" + teacher.slug + ")"));
      }
    }
    for (let i = 1; i <= gallerySlots; i++) slot.add(option(i,"Giá " + i));
    seasons.forEach((name,index) => season.add(option(index,name)));
    const current = () => gallery.find(row => row.teacher_slug === (scope.value || null) &&
      row.slot === Number(slot.value) && row.season === Number(season.value));
    function showSlot() {
      const row = current();
      $("cayPhotoCaption").value = row?.caption ?? "";
      $("cayPhotoDate").value = row?.photo_date ?? "";
      $("cayGalleryState").textContent = row ? "Giá này đang có ảnh." : "Giá này đang trống ở phạm vi đã chọn.";
    }
    async function loadGallery() {
      gallery = result(await client.from("cay_gallery").select("*"));
      showSlot();
    }
    [scope,slot,season].forEach(select => select.addEventListener("change",showSlot));
    action(cover,$("cayGalleryStatus"),async event => {
      const previous = current();
      if (event.submitter?.value === "remove") {
        if (!previous) return "Giá này đang trống.";
        result(await client.from("cay_gallery").delete().eq("id",previous.id));
        await removeUnused([previous.object_path]);
        await loadGallery();
        return "Đã gỡ ảnh khỏi giá.";
      }
      const file = $("cayClassFile").files[0];
      if (!file && !previous) throw new Error("Chọn ảnh để đặt lên giá.");
      const path = file ? await upload(file,"class") : previous.object_path;
      try {
        result(await client.from("cay_gallery").upsert({
          teacher_slug:scope.value || null,slot:Number(slot.value),season:Number(season.value),
          object_path:path,caption:clean($("cayPhotoCaption").value),photo_date:clean($("cayPhotoDate").value)
        },{onConflict:"teacher_slug,slot,season",defaultToNull:false}));
      } catch(error) {
        if (file) await removeUnused([path]);
        throw error;
      }
      if (file && previous) await removeUnused([previous.object_path]);
      $("cayClassFile").value = "";
      await loadGallery();
      return "Đã lưu ảnh lên giá.";
    });
    const folder = $("cayClassFolder");
    const batchStatus = $("cayClassBatchStatus");
    action($("cayClassBatch"),batchStatus,async () => {
      const files = [...folder.files].filter(file => /\.(jpe?g|png|webp)$/i.test(file.name));
      if (!files.length) throw new Error("Thư mục cần có ít nhất một ảnh JPG, PNG hoặc WebP.");
      files.sort((first,second) => (first.webkitRelativePath || first.name)
        .localeCompare(second.webkitRelativePath || second.name,"vi",{numeric:true}));
      files.forEach(photoFile);

      await loadGallery();
      const used = new Set(gallery.map(row => row.slot));
      const slots = Array.from({length:gallerySlots},(_, i) => i+1).filter(number => !used.has(number));
      if (files.length > slots.length) {
        throw new Error("Có " + files.length + " ảnh và " + slots.length + " giá trống. Hãy chọn một thư mục ít ảnh hơn.");
      }

      const rows = [];
      try {
        for (const [index,file] of files.entries()) {
          batchStatus.textContent = "Đang tải ảnh " + (index+1) + "/" + files.length + "…";
          const object_path = await upload(file,"class");
          rows.push({teacher_slug:null,slot:slots[index],season:-1,object_path});
        }
        const saved = result(await client.from("cay_gallery").insert(rows).select("*"));
        gallery.push(...saved);
      } catch(error) {
        await removeUnused(rows.map(row => row.object_path));
        if (error.code === "23505") throw new Error("Một giá ảnh vừa được sử dụng. Hãy thử lại để cập nhật các giá còn trống.");
        throw error;
      }
      showSlot();
      folder.value = "";
      return "Đã đặt " + rows.length + " ảnh chung lên cả bốn cây.";
    },"Đang kiểm tra thư mục ảnh…");
    action($("cayExport"), $("cayExportStatus"), exportMessages, "Đang xuất Excel…");
    action($("cayImport"), $("cayImportStatus"), async () => {
      const count = await importMessages($("cayImport"), teachers, roster);
      const refreshed = await client.from("cay_students").select("number,name").order("number");
      if (!refreshed.error) {
        roster.splice(0, roster.length, ...refreshed.data);
        $("cayRoster").value = roster.map(student => student.number + "," + student.name).join("\n");
      }
      return "Đã đưa " + count + " bài gửi lên cây.";
    }, "Đang nhập bài gửi…");

    function showProfile() {
      const teacher = teachers.find(item => item.slug === profileTeacher.value);
      if (!teacher) return;
      $("cayTeacherName").value = teacher.name;
      $("cayClassName").value = teacher.class_name;
      $("cayLetter").value = Array.isArray(teacher.letter.paragraphs) ? teacher.letter.paragraphs.join("\n\n") : "";
      $("caySignature").value = teacher.letter.signature ?? "";
    }
    profileTeacher.addEventListener("change",showProfile);
    showProfile();
    action(profile,$("cayProfileStatus"),async () => {
      const teacher = teachers.find(item => item.slug === profileTeacher.value);
      const name = clean($("cayTeacherName").value);
      if (!name) throw new Error("Nhập tên cô.");
      const fields = {name,class_name:clean($("cayClassName").value),letter:{...teacher.letter,
        paragraphs:$("cayLetter").value.trim().split(/\n\s*\n/).filter(Boolean),
        signature:clean($("caySignature").value)}};
      result(await client.from("cay_teachers").update(fields).eq("slug",teacher.slug));
      Object.assign(teacher,fields);
      return "Đã lưu hồ sơ cây.";
    });
    $("cayRoster").value = roster.map(student => student.number + "," + student.name).join("\n");
    const rosterFile = $("cayRosterFile");
    const rosterForm = $("cayRosterForm");
    const rosterStatus = $("cayRosterStatus");
    rosterFile.addEventListener("change", async () => {
      const file = rosterFile.files[0];
      if (!file) return;
      const save = rosterForm.querySelector("button[type=submit]");
      save.disabled = true;
      rosterStatus.textContent = "Đang đọc danh sách…";
      try {
        const data = await readRosterFile(file);
        if (rosterFile.files[0] !== file) return;
        $("cayRoster").value = data;
        rosterStatus.textContent = "Kiểm tra danh sách rồi bấm Lưu danh sách.";
      } catch (error) {
        if (rosterFile.files[0] === file) rosterStatus.textContent = error.message;
      } finally {
        if (!rosterFile.files[0] || rosterFile.files[0] === file) save.disabled = false;
      }
    });
    action(rosterForm,rosterStatus,async () => {
      const keys = new Set();
      const rows = $("cayRoster").value.split(/\r?\n/).filter(clean).map(line => {
        const match = line.match(/^\s*(\d+)\s*,\s*(.+)$/);
        const number = Number(match?.[1]);
        const name = clean(match?.[2]);
        if (!Number.isSafeInteger(number) || number < 1 || number > 10000 || !name || keys.has(number)) {
          throw new Error("Mỗi dòng cần mã học sinh và tên, ví dụ 1,Nguyễn Văn An.");
        }
        keys.add(number);
        return {number,name,class_roster: name !== "Học sinh " + number};
      });
      if (!rows.length) throw new Error("Danh sách lớp đang trống.");
      result(await client.from("cay_students").upsert(rows,{onConflict:"number"}));
      roster.splice(0,roster.length,...result(await client.from("cay_students").select("number,name").order("number")));
      $("cayRoster").value = roster.map(student => student.number + "," + student.name).join("\n");
      return "Đã lưu danh sách lớp.";
    });
    showSlot();
    $("cayLogin").hidden = true;
    $("cayAdmin").hidden = false;
    $("cayAdminSignout").addEventListener("click",signOut);
  }

  async function unlock(passcode, admin) {
    const code = passcode.replace(/[\s-]/g,"").toUpperCase();
    const invalidCode = admin ? "Mã quản lý chưa đúng." : "Mã truy cập chưa đúng. Cô kiểm tra lại mã được gửi nhé.";
    const format = admin ? /^(?:[0-9]{7}|[0-9A-F]{32})$/ : /^(?:[0-9]{6}|[0-9A-F]{20})$/;
    if (!format.test(code)) throw new Error(invalidCode);
    if (!guestReady) {
      const {error} = await client.auth.signInAnonymously();
      if (error) {
        if (error.code === "anonymous_provider_disabled") {
          throw new Error("Trang chưa mở cổng truy cập. Vui lòng quay lại sau.");
        }
        throw new Error("Chưa kết nối được. Vui lòng thử lại sau ít phút.");
      }
      guestReady = true;
    }
    const {data,error} = await client.rpc(admin ? "cay_unlock_admin" : "cay_unlock_tree",{p_code:code});
    if (error?.code === "PT429") throw new Error("Đã thử quá nhiều lần. Vui lòng đợi 10 phút rồi thử lại.");
    if (error) throw new Error(admin ? "Chưa mở được trang quản lý. Vui lòng thử lại." : "Chưa mở được cây. Cô thử lại sau ít phút nhé.");
    if (!data) throw new Error(invalidCode);
    return data;
  }

  function revealPublicTree(exitText, exitUrl) {
    $("cayPortal").hidden = true;
    document.body.removeAttribute("data-cay-locked");
    const exit = $("cayExit");
    exit.textContent = exitText;
    exit.hidden = false;
    exit.addEventListener("click",() => location.assign(exitUrl));
  }

  async function loadOwnSubmission(config, receipt, settings) {
    const studentClient = window.CayStudentSession?.client(settings);
    if (!studentClient) return false;
    const {data:{session}} = await studentClient.auth.getSession();
    if (!session) return false;
    const item = result(await studentClient.rpc("cay_read_own_submission", {
      p_id: receipt === "mine" ? null : receipt
    }).maybeSingle());
    if (!item) return false;

    await loadPublicTree(config,item.teacher_slug,settings);
    const isStory = !!item.story || item.photo_paths.length > 0;
    config.ownSubmission = {
      name: item.student_name,
      title: (isStory ? "Tâm sự của " : "Lời chúc của ") + item.student_name,
      text: isStory ? item.story : item.wish,
      photos: item.photo_paths,
      date: new Intl.DateTimeFormat("vi-VN", {
        timeZone: "Asia/Ho_Chi_Minh", day: "2-digit", month: "2-digit", year: "numeric"
      }).format(new Date(item.submitted_at)),
      hasStory: true
    };
    config.intro.enabled = false;
    client = studentClient;
    return true;
  }

  function setupStudentEntry(settings, showRoles) {
    const student = window.CayStudentSession;
    const studentClient = student?.client(settings);
    const studentRole = $("cayRoleStudent"), teacherRole = $("cayRoleTeacher");
    const studentPanel = $("cayStudentPanel"), teacherForm = $("cayLoginForm");
    const google = $("cayHomeGoogle"), link = $("cayStudentLink");
    const status = $("cayHomeStudentStatus");
    const hint = $("cayLoginHint");
    let accountId;

    if (showRoles) {
      function selectRole(isStudent) {
        studentRole.setAttribute("aria-pressed", String(isStudent));
        teacherRole.setAttribute("aria-pressed", String(!isStudent));
        studentPanel.hidden = !isStudent;
        teacherForm.hidden = isStudent;
        hint.textContent = isStudent
          ? "Đăng nhập để gửi lời chúc và tâm sự."
          : "Thầy cô nhập mã được gửi riêng để mở cây.";
      }
      $("cayRolePicker").hidden = false;
      studentRole.addEventListener("click", () => selectRole(true));
      teacherRole.addEventListener("click", () => selectRole(false));
      selectRole(true);
      if (!studentClient) status.textContent = "Chưa tải được đăng nhập. Bạn thử tải lại trang nhé.";
      google.addEventListener("click", async () => {
        google.disabled = true;
        status.textContent = "Đang mở Google…";
        try {
          await student.signIn(studentClient);
        } catch {
          status.textContent = "Chưa mở được Google. Bạn thử lại nhé.";
          google.disabled = false;
        }
      });
    }

    if (!studentClient) return;
    student.bindSignOut(studentClient);
    studentClient.auth.onAuthStateChange((event, session) => {
      if (accountId && (event === "SIGNED_OUT" || (session && session.user.id !== accountId))) {
        student.returnToLogin();
      }
    });
    async function restoreAccount() {
      try {
        const {data:{session}} = await studentClient.auth.getSession();
        if (!session) return;
        accountId = session.user.id;
        student.showAccount(session.user.email ?? "Tài khoản Google");
        link.hidden = false;
        google.hidden = true;
        const [profile] = result(await studentClient.rpc("cay_get_student_account"));
        if (profile) student.showAccount(profile.student_name);
      } catch {
        if (accountId) status.textContent = "Bạn có thể mở trang học sinh để tải lại thông tin.";
      } finally {
        google.disabled = false;
      }
    }
    void restoreAccount();
  }

  async function start(config) {
    const query = new URLSearchParams(location.search);
    const admin = query.get("admin") === "1";
    const publicSlug = query.get("xem") ?? "";
    const receipt = query.get("bai");
    const form = $("cayLoginForm");
    const password = $("cayPassword");
    const status = $("cayLoginStatus");
    const settings = window.CAY_SUPABASE;
    const siteName = config.siteName || "Cây Kí Ức";
    $("cayLoginTitle").textContent = admin ? "Quản lý " + siteName : siteName;
    if (admin) $("cayLoginHint").textContent = "Nhập mã quản lý để thêm ảnh lớp và chỉnh nội dung.";
    $("cayAdminLink").hidden = admin;
    if (!admin) setupStudentEntry(settings, receipt === null);
    $("cayPasswordLabel").textContent = admin ? "Mã quản lý" : "Mã của cô giáo";
    $("cayLoginSubmit").textContent = admin ? "Mở trang quản lý" : "Mở cây";
    password.inputMode = "numeric";
    password.maxLength = 60;
    if (!admin && receipt !== null) {
      $("cayLoginTitle").textContent = "Bài của mình";
      const hint = $("cayLoginHint"), back = $("cayPublicLink");
      form.hidden = true;
      back.href = "./gui-bai.html";
      back.textContent = "Về biểu mẫu";
      hint.textContent = "Đang mở bài gửi…";
      try {
        const validReceipt = receipt === "mine" || /^[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12}$/i.test(receipt);
        if (validReceipt && await loadOwnSubmission(config,receipt,settings)) {
          revealPublicTree("Về biểu mẫu","./gui-bai.html");
          return true;
        }
        hint.textContent = "Chưa tìm thấy bài. Bạn đăng nhập bằng Google đã dùng để gửi bài rồi mở lại từ mục Bài đã gửi nhé.";
      } catch {
        hint.textContent = "Chưa mở được bài gửi. Hãy tải lại trang để thử lại.";
      }
      return false;
    }
    if (!settings?.url || !settings.publishableKey) {
      status.textContent = "Trang đang chờ cấu hình kết nối Supabase.";
      $("cayLoginSubmit").disabled = true;
      return false;
    }
    if (!admin && /^co-[1-4]$/.test(publicSlug)) {
      status.textContent = "Đang mở cây…";
      try {
        await loadPublicTree(config,publicSlug,settings);
        revealPublicTree("Chọn cây khác","./loi-chuc.html");
        return true;
      } catch {
        status.textContent = "Chưa mở được cây công khai. Hãy tải lại trang để thử lại.";
      }
    }
    if (!window.supabase) {
      status.textContent = "Chưa tải được phần đăng nhập. Tải lại trang để thử lại.";
      $("cayLoginSubmit").disabled = true;
      return false;
    }
    client = window.supabase.createClient(settings.url,settings.publishableKey,{
      auth:{persistSession:false,autoRefreshToken:true,detectSessionInUrl:false}
    });
    $("cayLoginSubmit").disabled = false;
    return new Promise(resolve => {
      action(form,status,async () => {
        const access = await unlock(password.value,admin);
        password.value = "";
        if (admin) {
          try {
            await openAdmin();
            resolve(false);
          } catch(error) {
            guestReady = false;
            await client.auth.signOut({scope:"local"});
            throw error;
          }
        } else {
          await loadTree(config,access);
          $("cayPortal").hidden = true;
          document.body.removeAttribute("data-cay-locked");
          $("cayExit").hidden = false;
          $("cayExit").addEventListener("click",signOut);
          resolve(true);
        }
        return "";
      },admin ? "Đang mở trang quản lý…" : "Đang mở cây…");
    });
  }

  async function openStoryPhoto(path, image) {
    const blob = result(await client.storage.from(bucketName).download(path));
    const url = URL.createObjectURL(blob);
    image.src = url;
    return () => { image.removeAttribute("src"); URL.revokeObjectURL(url); };
  }

  window.CayData = {start,openStoryPhoto};
})();
