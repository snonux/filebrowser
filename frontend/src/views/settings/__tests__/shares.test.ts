// @vitest-environment jsdom
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { createApp, nextTick, type App } from "vue";
import Shares from "../Shares.vue";

const mocks = vi.hoisted(() => ({
  list: vi.fn(),
  remove: vi.fn(),
  showHover: vi.fn(),
  closeHovers: vi.fn(),
  success: vi.fn(),
  error: vi.fn(),
}));
vi.mock("@/api", () => ({
  share: {
    list: mocks.list,
    remove: mocks.remove,
    getShareURL: () => "/share/test",
  },
  users: { getAll: vi.fn() },
}));
vi.mock("@/stores/layout", () => ({
  useLayoutStore: () => ({
    loading: false,
    showHover: mocks.showHover,
    closeHovers: mocks.closeHovers,
  }),
}));
vi.mock("@/stores/auth", () => ({
  useAuthStore: () => ({ user: { perm: { admin: false } } }),
}));
vi.mock("vue-i18n", () => ({ useI18n: () => ({ t: (key: string) => key }) }));

vi.mock("@/views/Errors.vue", () => ({ default: { template: "<div />" } }));

let app: App;
let host: HTMLDivElement;
async function mount() {
  host = document.createElement("div");
  document.body.append(host);
  app = createApp(Shares);
  app.provide("$showSuccess", mocks.success);
  app.provide("$showError", mocks.error);
  app.mount(host);
  await vi.waitFor(() =>
    expect(host.querySelector("a")?.textContent).toBe("/file.txt")
  );
}
function confirmDelete(): Promise<void> {
  host
    .querySelector<HTMLButtonElement>('button[aria-label="buttons.delete"]')!
    .click();
  return mocks.showHover.mock.calls.at(-1)![0].confirm();
}
beforeEach(() => {
  vi.clearAllMocks();
  mocks.list.mockResolvedValue([
    { hash: "test", path: "/file.txt", expire: 0 },
  ]);
});
afterEach(() => {
  app?.unmount();
  host?.remove();
});

describe("share deletion", () => {
  it("waits for the server before removing the link or reporting success", async () => {
    let resolve!: () => void;
    mocks.remove.mockReturnValue(
      new Promise<void>((done) => {
        resolve = done;
      })
    );
    await mount();
    const deletion = confirmDelete();
    await nextTick();
    expect(host.textContent).toContain("/file.txt");
    expect(mocks.success).not.toHaveBeenCalled();
    resolve();
    await deletion;
    await nextTick();
    expect(host.textContent).not.toContain("/file.txt");
    expect(mocks.remove).toHaveBeenCalledWith("test");
    expect(mocks.success).toHaveBeenCalledOnce();
  });
  it("retains the link and reports an asynchronous server rejection", async () => {
    const error = new Error("Share deletion failed");
    mocks.remove.mockRejectedValue(error);
    await mount();
    await confirmDelete();
    await nextTick();
    expect(host.textContent).toContain("/file.txt");
    expect(mocks.error).toHaveBeenCalledWith(error);
    expect(mocks.success).not.toHaveBeenCalled();
  });
});
