(() => {
  "use strict";

  window.CayStudentSession = settings => window.supabase.createClient(settings.url, settings.publishableKey, {
    auth: {
      storageKey: "cay-student-google",
      persistSession: true,
      flowType: "pkce",
      detectSessionInUrl: false
    }
  });
})();
