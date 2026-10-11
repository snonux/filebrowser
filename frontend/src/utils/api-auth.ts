import { configureApiAuth } from "@/api/utils";
import {
  captureAuthSession,
  isCurrentAuthSession,
  renew,
  logout,
} from "./auth";

export function configureApplicationApiAuth() {
  configureApiAuth({
    captureSession: captureAuthSession,
    isCurrentSession: isCurrentAuthSession,
    renew,
    logout,
  });
}
