(() => {
  "use strict";

  let studentClient;

  function client(settings) {
    if (!window.supabase || !settings?.url || !settings.publishableKey) return null;
    studentClient ??= window.supabase.createClient(settings.url, settings.publishableKey, {
      auth: {
        storageKey: "cay-student-google",
        persistSession: true,
        flowType: "pkce",
        detectSessionInUrl: false
      }
    });
    return studentClient;
  }

  async function signIn(client, messageTarget = "") {
    const key = "cay-student-next-message";
    if (messageTarget) sessionStorage.setItem(key, messageTarget);
    else sessionStorage.removeItem(key);
    const redirectTo = new URL("./gui-bai.html", location.href).href;
    const {error} = await client.auth.signInWithOAuth({
      provider: "google", options: {redirectTo, queryParams: {prompt: "select_account"}}
    });
    if (error) throw error;
  }

  function showAccount(name) {
    const identity = document.getElementById("studentIdentity");
    identity.textContent = name;
    identity.title = name;
    document.getElementById("studentAccount").hidden = false;
  }

  function returnToLogin() {
    location.replace("./?dang-nhap=1");
  }

  async function isAdmin(client) {
    const {data, error} = await client.rpc("cay_is_admin");
    return !error && data === true;
  }

  async function showAdminShortcut(client) {
    if (!await isAdmin(client)) return;
    const dock = document.getElementById("studentAccount");
    if (dock.querySelector(".cay-admin-shortcut")) return;
    const link = document.createElement("a");
    link.className = "cay-admin-shortcut";
    link.href = "./?admin=1";
    link.textContent = "Quản lý";
    link.title = "Quản lý lời chúc và ảnh lớp";
    document.getElementById("studentSignOut").before(link);
  }

  async function restoreAccount(client) {
    const {data:{session}} = await client.auth.getSession();
    if (!session) return null;
    client.auth.onAuthStateChange((event, next) => {
      if (event === "SIGNED_OUT" || (next && next.user.id !== session.user.id)) returnToLogin();
    });
    showAccount(session.user.email ?? "Tài khoản Google");
    const {data, error} = await client.rpc("cay_get_student_account");
    const profile = error ? null : data?.[0];
    if (profile) {
      showAccount(profile.student_name);
      showAdminShortcut(client).catch(() => {});
    }
    return {profile};
  }

  function bindSignOut(client) {
    const button = document.getElementById("studentSignOut");
    const status = document.getElementById("studentAccountStatus");
    button.addEventListener("click", async () => {
      button.disabled = true;
      status.textContent = "";
      try {
        const {error} = await client.auth.signOut({scope: "local"});
        if (error) throw error;
        returnToLogin();
      } catch {
        status.textContent = "Chưa đăng xuất được. Bạn thử lại nhé.";
        button.disabled = false;
      }
    });
  }

  window.CayStudentSession = {client, signIn, restoreAccount, showAccount, bindSignOut, returnToLogin, isAdmin};
})();
