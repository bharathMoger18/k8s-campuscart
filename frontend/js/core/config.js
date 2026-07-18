// js/core/config.js
const isLocal = window.location.hostname === 'localhost' || window.location.hostname === '127.0.0.1';
export const API_BASE = isLocal
  ? 'http://localhost:8080/api/v1'
  : 'https://campuscart-docker.onrender.com/api/v1';
export const REFRESH_ENDPOINT = '/auth/token/refresh/';
export const LOGIN_ENDPOINT = '/auth/token/';
