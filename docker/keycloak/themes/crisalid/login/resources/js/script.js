(function () {
    function ready(fn) {
        if (document.readyState === "loading") {
            document.addEventListener("DOMContentLoaded", fn);
        } else {
            fn();
        }
    }

    ready(function () {

        const formWrapper =
            document.getElementById("kc-form-wrapper") ||
            document.getElementById("kc-form") ||
            document.body;

        const loginForm = document.getElementById("kc-form-login");
        const social = document.getElementById("kc-social-providers");

        // Remove <hr> inside kc-social-providers
        const hr = social.querySelector("hr");
        if (hr) hr.remove();

        // Remove <h2> inside kc-social-providers
        const h2 = social.querySelector("h2");
        if (h2) h2.remove();

        // Update header texts
        const headerWrapper = document.getElementById("kc-header-wrapper");
        if (headerWrapper) {
            headerWrapper.textContent = "Système d'information pour la recherche";
        }
        const pageTitle = document.getElementById("kc-page-title");
        if (pageTitle) {
            pageTitle.textContent = "Authentification";
        }

        if (!formWrapper) return;

        // --- 2) Put Social providers first (if present) ---
        if (social && social.parentElement) {
            social.dataset.moved = social.dataset.moved || "1";
            if (social.dataset.moved === "1") {
                formWrapper.insertBefore(social, formWrapper.firstChild);
            }
        }

        // --- 3) Hide password login behind a collapsed <details> ---
        if (!loginForm || !loginForm.parentElement) return;

        if (loginForm.dataset.wrapped === "1") return;
        loginForm.dataset.wrapped = "1";

        const userInput = loginForm.querySelector('input[name="username"], input#username');
        const passInput = loginForm.querySelector('input[name="password"], input#password');

        // Prevent suggestions on page load
        function lockInputs() {
            if (userInput) {
                userInput.dataset.prevAutocomplete = userInput.getAttribute("autocomplete") || "";
                userInput.setAttribute("autocomplete", "off");
                userInput.setAttribute("autocapitalize", "off");
                userInput.setAttribute("spellcheck", "false");
                userInput.disabled = true;
            }
            if (passInput) {
                passInput.dataset.prevAutocomplete = passInput.getAttribute("autocomplete") || "";
                passInput.setAttribute("autocomplete", "off");
                passInput.disabled = true;
            }
        }

        function unlockInputs() {
            if (userInput) {
                userInput.disabled = false;
                const prev = userInput.dataset.prevAutocomplete;
                if (prev) userInput.setAttribute("autocomplete", prev);
                else userInput.removeAttribute("autocomplete");
            }
            if (passInput) {
                passInput.disabled = false;
                const prev = passInput.dataset.prevAutocomplete;
                if (prev) passInput.setAttribute("autocomplete", prev);
                else passInput.removeAttribute("autocomplete");
            }
        }

        lockInputs();

        const details = document.createElement("details");
        details.id = "kc-password-details";

        const summary = document.createElement("summary");
        summary.id = "kc-password-summary";
        summary.textContent = "⚙";
        summary.setAttribute("role", "button");

        details.appendChild(summary);

        loginForm.parentElement.insertBefore(details, loginForm);
        details.appendChild(loginForm);

        details.addEventListener("toggle", () => {
            if (details.open) {
                unlockInputs();
                if (userInput) userInput.focus();
            } else {
                lockInputs();
            }
        });

    });
})();
