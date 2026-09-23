#!/usr/bin/env python
# -*- coding: utf-8 -*-

import logging
import os
from typing import Optional

logger = logging.getLogger("bilibili_runtime")

_INITIALIZED = False
_LAST_ERROR: Optional[str] = None


def configure_bilibili_runtime() -> bool:
    """Configure the internal Bilibili SDK network runtime once per process.

    2026-08-05 关键修复（根因）：
    bili_sdk 的 CurlCFFIClient.__init__ **总是传 proxies={"all": proxy}** 给 curl_cffi AsyncSession。
    curl_cffi 一旦收到 proxies 字典（即使值是空字符串 ""），就走代理路径 → 解析失败 → 30s 超时。
    即使 trust_env=False 也救不了，因为 proxy 参数显式传了字典。

    修复：monkey patch CurlCFFIClient.__init__，在 proxy 为空时**不传 proxies 参数**，
    让 curl_cffi 默认 proxies={}，走直连路径。
    """
    global _INITIALIZED, _LAST_ERROR
    if _INITIALIZED:
        return True

    try:
        from .bili_sdk import request_settings
        from .bili_sdk.clients import CurlCFFIClient as _CffiClient

        impersonate = os.environ.get("BILIBILI_IMPERSONATE", "chrome131").strip()
        if impersonate:
            request_settings.set("impersonate", impersonate)

        # Monkey patch: 创建子类 + 重新注册（直接改 class.__init__ 不生效，类的 __init__ 在自己 __dict__）
        # 注意：必须从子模块 import，CurlCFFIClient 是模块下的类
        from .bili_sdk.clients.CurlCFFIClient import CurlCFFIClient as _CffiClientCls
        _orig_class = _CffiClientCls

        class _PatchedCffiClient(_orig_class):
            """子类：实例化后强制 proxies={} 和 trust_env=False，绕过代理路径"""

            def __init__(self, *args, **kwargs):
                super().__init__(*args, **kwargs)
                try:
                    self._CurlCFFIClient__session.proxies = {}
                    self._CurlCFFIClient__session.trust_env = False
                except Exception as exc:
                    logger.warning("PATCHED class proxies clear failed: %s", exc)

        # 重新注册让 bili_sdk 用新类
        from .bili_sdk.utils.network import register_client as _reg
        _reg("curl_cffi", _PatchedCffiClient, {"impersonate": impersonate or "", "http2": False})
        logger.info("bilibili runtime: 注册 PatchedCffiClient 子类，强制 proxies={}")

        # 清空已缓存的 session（之前创建的 session 还是旧类）
        from .bili_sdk.utils import network as _bili_network
        selected_client = getattr(_bili_network, 'selected_client', '')
        session_pool = getattr(_bili_network, 'session_pool', None)
        if selected_client and isinstance(session_pool, dict):
            session_pool[selected_client] = {}
            logger.info("已清空 bili_sdk session pool[%s]，下次 get_client 用新类重建", selected_client)

        _INITIALIZED = True
        _LAST_ERROR = None
        return True
    except Exception as exc:
        _LAST_ERROR = str(exc)
        logger.warning("配置 bilibili-api 网络运行时失败: %s", exc)
        return False


def get_bilibili_runtime_error() -> Optional[str]:
    return _LAST_ERROR
