// Scripting for Generic API calls.

// Show a generic error toast with a given header and message.
function showErrorToast(header, error) {
    $.toast({
        showHideTransition: "slide",
        position: "top-left",
        loader: false,
        heading: header,
        text: error,
        hideAfter: false,
        icon: "error",
    });
}

// Call that shows a popup to the user on success/failure.
// Returns the promise so you can add final callbacks if needed.
// Endpoint: URL endpoint
// Method: GET/PUT/DELETE/POST
// successMessage: Message written in the toast if request succeeded (success = 1)
// errorMessage: Header of the error message if request fails (success = 0)
// successCallback: Func called if request succeeded
function genericAPICall(endpoint, method, successMessage, errorMessage, successCallback) {
    return fetch(endpoint, { method })
        .then((response) => (response.ok ? response.json() : { success: 0, error: "响应不正确" }))
        .then((data) => {
            if (Object.prototype.hasOwnProperty.call(data, "success") && !data.success) {
                throw new Error(data.error);
            } else {
                if (successMessage !== null) {
                    $.toast({
                        showHideTransition: "slide",
                        position: "top-left",
                        loader: false,
                        heading: successMessage,
                        icon: "success",
                    });
                }

                if (successCallback !== null) return successCallback(data);
            }
        })
        .catch((error) => showErrorToast(errorMessage, error));
}

// Check the status of a Minion job until it's completed.
// Execute a callback on successful job completion.
function checkJobStatus(jobId, callback, failureCallback) {
    fetch(`/api/minion/${jobId}`, { method: "GET" })
        .then((response) => (response.ok ? response.json() : { success: 0, error: "响应不正确" }))
        .then((data) => {
            if (data.error) throw new Error(data.error);

            if (data.state === "failed") {
                throw new Error(data.result);
            }

            if (data.state !== "finished") {
                // Wait and retry, job isn't done yet
                setTimeout(() => {
                    checkJobStatus(jobId, callback, failureCallback);
                }, 1000);
            } else {
                // Update UI with info
                callback(data);
            }
        })
        .catch((error) => { showErrorToast("检查 Minion 工作状态时出错", error); failureCallback(error); });
}

// saveFormData()
// POSTs the data of the specified form to the page.
// This is used for Edit, Config and Plugins.
// Returns the promise object so you can chain more callbacks.
function saveFormData(formSelector) {
    const postData = new FormData($(formSelector)[0]);

    return fetch(window.location.href, { method: "POST", body: postData })
        .then((response) => (response.ok ? response.json() : { success: 0, error: "响应不正确" }))
        .then((data) => {
            if (data.success) {
                $.toast({
                    showHideTransition: "slide",
                    position: "top-left",
                    loader: false,
                    heading: "保存成功！",
                    icon: "success",
                });
            } else {
                throw new Error(data.message);
            }
        })
        .catch((error) => showErrorToast("保存出错", error));
}

let isScriptRunning = false;
function triggerScript(namespace) {
    const scriptArg = $(`#${namespace}_ARG`).val();

    if (isScriptRunning) {
        showErrorToast("一个脚本已在运行。", "请等待脚本终止。");
        return;
    }

    isScriptRunning = true;
    $(".script-running").show();
    $(".stdbtn").hide();

    // Save data before triggering script
    saveFormData("#editPluginForm")
        .then(genericAPICall(`/api/plugins/queue?plugin=${namespace}&arg=${scriptArg}`, "POST", null, "执行脚本时出错:",
            (data) => {
                // Check minion job state periodically while we're on this page
                checkJobStatus(data.job,
                    (d) => {
                        isScriptRunning = false;
                        $(".script-running").hide();
                        $(".stdbtn").show();

                        if (d.result.success === 1) {
                            $.toast({
                                showHideTransition: "slide",
                                position: "top-left",
                                loader: false,
                                heading: "Script result",
                                text: `<pre>${JSON.stringify(d.result.data, null, 4)}</pre>`,
                                hideAfter: false,
                                icon: "info",
                            });
                        } else showErrorToast(`Script failed: ${d.result.error}`);
                    },
                    (error) => {
                        isScriptRunning = false;
                        $(".script-running").hide();
                        $(".stdbtn").show();
                    });
            }));
}

function cleanTempFldr() {
    genericAPICall("/api/tempfolder", "DELETE", "临时文件夹已清理!", "清理临时文件夹时出错 :",
        (data) => {
            $("#tempsize").html(data.newsize);
        });
}

function invalidateCache() {
	genericAPICall("/api/search/cache", "DELETE", "丢弃搜索缓存!", "删除缓存时出错！ 请检查日志。", null);
}

function clearNew(id) {
	genericAPICall(`/api/archives/${id}/isnew`, "DELETE", null, "清除新标签时出错！请检查日志。", null);
}

function clearAllNew() {
	genericAPICall("/api/database/isnew", "DELETE", "所有档案不再是新的!", "清除标签时出错！ 请检查日志。", null);
}

function dropDatabase() {
    if (confirm("危险！ 你*确定*要这么做吗?")) {
        genericAPICall("/api/database/drop", "POST", "Sayonara! 重定向...", "重置数据库时出错？ 请检查日志。",
            (data) => {
                setTimeout("location.href = './';", 1500);
            });
    }
}

function cleanDatabase() {
	genericAPICall("/api/database/clean", "POST", null, "清理数据库时出错！ 请检查日志。",
        (data) => {
            $.toast({
                showHideTransition: "slide",
                position: "top-left",
                loader: false,
                heading: `成功清理数据库并删除 ${data.deleted} 条!`,
                icon: "success",
            });

            if (data.unlinked > 0) {
                $.toast({
                    showHideTransition: "slide",
                    position: "top-left",
                    loader: false,
                    heading: `${data.unlinked} 其他条目已从数据库取消链接，将在下次清理时删除！ <br>如果某些文件从存档索引中消失，请立即进行备份。`,
                    hideAfter: false,
                    icon: "warning",
                });
            }
        });
}

function regenThumbnails(force) {
    forceparam = force ? 1 : 0;
    genericAPICall(`/api/regen_thumbs?force=${forceparam}`, "POST",
        "排队重新生成缩略图！ 请继续关注更新或查看 Minion 控制台。", "向 Minion 发送作业时出错:",
        (data) => {
            // Disable the buttons to avoid accidental double-clicks.
            $("#genthumb-button").prop("disabled", true);
            $("#forcethumb-button").prop("disabled", true);

            // Check minion job state periodically while we're on this page
            checkJobStatus(data.job,
                (d) => {
                    $("#genthumb-button").prop("disabled", false);
                    $("#forcethumb-button").prop("disabled", false);
                    $.toast({
                        showHideTransition: "slide",
                        position: "top-left",
                        loader: false,
                        heading: "所有缩略图已生成！ 遇到以下错误:",
                        text: d.result.errors,
                        hideAfter: false,
                        icon: "success",
                    });
                },
                (error) => {
                    $("#genthumb-button").prop("disabled", false);
                    $("#forcethumb-button").prop("disabled", false);
                    showErrorToast("缩略图重新生成失败！", error);
                });
        });
}

function rebootShinobu() {
    $("#restart-button").prop("disabled", true);
    genericAPICall("/api/shinobu/restart", "POST", "后台服务重启!", "重启后台服务失败:",
        (data) => {
            $("#restart-button").prop("disabled", false);
            shinobuStatus();
        });
}

// Update the status of the background worker.
function shinobuStatus() {
    genericAPICall("/api/shinobu", "GET", null, "获取Shinobu状态失败:",
        (data) => {
            if (data.is_alive) {
                $("#shinobu-ok").show();
                $("#shinobu-ko").hide();
            } else {
                $("#shinobu-ko").show();
                $("#shinobu-ok").hide();
            }
            $("#pid").html(data.pid);
        });
}

// Adds an archive to a category. Basic implementation to use everywhere.
function addArchiveToCategory(arcId, catId) {
    genericAPICall(`/api/categories/${catId}/${arcId}`, "PUT", `添加 ${arcId} 到分类 ${catId}!`, "添加/移除档案到分类失败", null);
}

// Ditto, but for removing.
function removeArchiveFromCategory(arcId, catId) {
    genericAPICall(`/api/categories/${catId}/${arcId}`, "DELETE", `移除 ${arcId} 自分类 ${catId}!`, "将存档从类别添加/删除时出错", null);
}

// deleteArchive(id)
// Sends a DELETE request for that archive ID, deleting the Redis key and attempting to delete the archive file.
function deleteArchive(arcId) {
    fetch(`/api/archives/${arcId}`, { method: "DELETE" })
        .then((response) => (response.ok ? response.json() : { success: 0, error: "响应不正确" }))
        .then((data) => {
            if (data.success == "0") {
                $.toast({
                    showHideTransition: "slide",
                    position: "top-left",
                    loader: false,
                    heading: "无法删除存档文件。 <br> (也许它已经被事先删除了?)",
                    text: "存档元数据已正确删除。 <br> 请先手动删除文件，然后再返回“资料库”。",
                    hideAfter: false,
                    icon: "warning",
                });
                $(".stdbtn").hide();
                $("#goback").show();
            } else {
                $.toast({
                    showHideTransition: "slide",
                    position: "top-left",
                    loader: false,
                    heading: "存档已成功删除。重定向 ...",
                    text: `...`,
                    icon: "success",
                });
                setTimeout("location.href = './';", 1500);
            }
        })
        .catch((error) => showErrorToast("删除存档时出错", error));
}
