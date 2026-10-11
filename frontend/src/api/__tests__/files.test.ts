import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { copy, move } from "../files";
import { configureApiAuth } from "../utils";

vi.mock("@/utils/constants", () => ({ baseURL: "", tusSettings: undefined }));

beforeEach(() => {
  vi.stubGlobal("fetch", vi.fn().mockResolvedValue(new Response("{}")));
  configureApiAuth({
    captureSession: () => ({ jwt: "token", generation: 1 }),
    isCurrentSession: () => true,
    renew: async () => {},
    logout: () => {},
  });
});
afterEach(() => vi.unstubAllGlobals());

describe("file copy/move transport without router or store mocks", () => {
  it.each([copy, move])(
    "encodes destinations and respects per-item conflict choices",
    async (action) => {
      await action(
        [
          {
            from: "/files/source/a",
            to: "/files/target/a b",
            overwrite: true,
            rename: false,
          },
          { from: "/files/source/b", to: "/files/target/b" },
        ],
        false,
        true
      );
      const operation = action === copy ? "copy" : "rename";
      expect(fetch).toHaveBeenNthCalledWith(
        1,
        `/api/resources/source/a?action=${operation}&destination=%2Ftarget%2Fa%20b&override=true&rename=false`,
        {
          method: "PATCH",
          headers: { "X-Auth": "token" },
        }
      );
      expect(fetch).toHaveBeenNthCalledWith(
        2,
        `/api/resources/source/b?action=${operation}&destination=%2Ftarget%2Fb&override=false&rename=true`,
        {
          method: "PATCH",
          headers: { "X-Auth": "token" },
        }
      );
    }
  );

  it("propagates server conflicts", async () => {
    vi.mocked(fetch).mockResolvedValueOnce(
      new Response("exists", { status: 409 })
    );
    await expect(
      copy([{ from: "/files/source/a", to: "/files/target/a" }])
    ).rejects.toMatchObject({ status: 409, message: "exists" });
  });
});
