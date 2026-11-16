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

  async function signIn(client) {
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

  window.CayStudentSession = {client, signIn, showAccount, bindSignOut, returnToLogin};
})();
