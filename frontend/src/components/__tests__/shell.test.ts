// @vitest-environment jsdom
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { createApp, nextTick, type App } from "vue";
import Shell from "../Shell.vue";

const mocks = vi.hoisted(() => ({ run: vi.fn(), toggle: vi.fn() }));
vi.mock("@/api", () => ({ commands: mocks.run }));
vi.mock("@/utils/constants", () => ({ theme: "light" }));
vi.mock("@/stores/layout", () => ({
  useLayoutStore: () => ({ showShell: true, toggleShell: mocks.toggle }),
}));
vi.mock("@/stores/file", () => ({
  useFileStore: () => ({ isFiles: true }),
}));

let app: App;
let host: HTMLDivElement;
async function submit() {
  host = document.createElement("div");
  document.body.append(host);
  app = createApp(Shell);
  app.config.globalProperties.$route = { path: "/files/" };
  app.mount(host);
  const input = host.querySelector<HTMLElement>("[contenteditable]")!;
  input.innerText = "echo testing";
  input.dispatchEvent(
    new KeyboardEvent("keypress", { key: "Enter", bubbles: true })
  );
  await nextTick();
  return {
    receive: mocks.run.mock.calls[0][2] as (event: { data: string }) => void,
    close: mocks.run.mock.calls[0][3] as () => void,
  };
}
beforeEach(() => {
  vi.clearAllMocks();
  document.documentElement.style.fontSize = "16px";
});
afterEach(() => {
  app?.unmount();
  host?.remove();
});

describe("shell output", () => {
  it("renders streamed output while the command is still running", async () => {
    const command = await submit();
    command.receive({ data: "streamed progress" });
    await nextTick();
    expect(host.textContent).toContain("streamed progress");
    expect(host.querySelector(".shell__result--hidden")).not.toBeNull();
  });
  it("renders an immediate rejection followed by close in the same turn", async () => {
    const command = await submit();
    command.receive({ data: "Command not allowed." });
    command.close();
    await nextTick();
    expect(host.textContent).toContain("Command not allowed.");
    expect(host.querySelector(".shell__result--hidden")).toBeNull();
  });
});
